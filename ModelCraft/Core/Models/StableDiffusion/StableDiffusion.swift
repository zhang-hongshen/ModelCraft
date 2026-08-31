// Copyright © 2024 Apple Inc.

import Foundation
import CoreGraphics
import ImageIO
import Hub
import MLX
import MLXNN


struct StableDiffusionConditioning {
    let conditioning: MLXArray
    let textTime: (MLXArray, MLXArray)?
}

/// Base class for Stable Diffusion.
open class StableDiffusion {

    let hub: HubApi
    let configuration: StableDiffusionConfiguration
    let loadConfiguration: LoadConfiguration
    let dType: DType
    let diffusionConfiguration: DiffusionConfiguration
    let autoencoderConfiguration: AutoencoderConfiguration
    let sampler: SimpleEulerSampler
    let tokenizer: StableDiffusionTokenizer

    var unet: StableDiffusionUNet?
    var textEncoder: StableDiffusionTextEncoder?
    var autoencoder: Autoencoder?

    private var conditioningCache =
        StableDiffusionConditioningCache<StableDiffusionConditioning>()

    var releasesComponentsBetweenStages: Bool {
        loadConfiguration.releasesComponentsBetweenStages
    }

    internal init(
        hub: HubApi, configuration: StableDiffusionConfiguration,
        loadConfiguration: LoadConfiguration,
        diffusionConfiguration: DiffusionConfiguration? = nil,
        sampler: SimpleEulerSampler? = nil,
        tokenizer: StableDiffusionTokenizer? = nil
    ) throws {
        self.hub = hub
        self.configuration = configuration
        self.loadConfiguration = loadConfiguration
        self.dType = loadConfiguration.dType
        self.diffusionConfiguration =
            try diffusionConfiguration
            ?? StableDiffusionLoader.loadDiffusionConfiguration(
                hub: hub, configuration: configuration)
        self.autoencoderConfiguration = try StableDiffusionLoader.loadConfiguration(
            hub: hub, configuration: configuration, key: .vaeConfig,
            type: AutoencoderConfiguration.self)
        self.sampler = sampler ?? SimpleEulerSampler(configuration: self.diffusionConfiguration)
        self.tokenizer = try tokenizer ?? StableDiffusionLoader.loadTokenizer(
            hub: hub, configuration: configuration)
    }

    open func ensureLoaded() throws {
        guard !releasesComponentsBetweenStages else {
            return
        }

        let unet = try loadUNet()
        let textEncoder = try loadTextEncoder()
        let autoencoder = try loadAutoencoder()
        eval(unet, textEncoder, autoencoder)
    }

    func loadTextEncoder(
        configKey: StableDiffusionFileKey = .textEncoderConfig,
        weightsKey: StableDiffusionFileKey = .textEncoderWeights
    ) throws -> StableDiffusionTextEncoder {
        let textEncoder = try StableDiffusionLoader.loadTextEncoder(
            hub: hub, configuration: configuration, configKey: configKey,
            weightsKey: weightsKey, dType: dType)
        if let quantization = loadConfiguration.textEncoderQuantization {
            quantize(
                model: textEncoder, groupSize: quantization.groupSize,
                bits: quantization.bits, filter: { _, module in module is Linear })
        }
        return textEncoder
    }

    func loadTextEncoder() throws -> StableDiffusionTextEncoder {
        if let textEncoder {
            return textEncoder
        }
        let textEncoder = try loadTextEncoder(
            configKey: .textEncoderConfig, weightsKey: .textEncoderWeights)
        self.textEncoder = textEncoder
        return textEncoder
    }

    func loadUNet() throws -> StableDiffusionUNet {
        if let unet {
            return unet
        }
        let unet = try StableDiffusionLoader.loadUnet(
            hub: hub, configuration: configuration, dType: dType)
        if let quantization = loadConfiguration.unetQuantization {
            quantize(
                model: unet, groupSize: quantization.groupSize, bits: quantization.bits)
        }
        self.unet = unet
        return unet
    }

    func loadAutoencoder() throws -> Autoencoder {
        if let autoencoder {
            return autoencoder
        }
        let autoencoder = try StableDiffusionLoader.loadAutoEncoder(
            hub: hub, configuration: configuration, dType: .float32)
        self.autoencoder = autoencoder
        return autoencoder
    }

    func releaseTextEncoders() {
        textEncoder = nil
    }

    func tokenize(
        tokenizer: StableDiffusionTokenizer, text: String, negativeText: String?
    ) -> MLXArray {
        var tokens = [tokenizer.tokenize(text: text)]
        if let negativeText {
            tokens.append(tokenizer.tokenize(text: negativeText))
        }

        let count = tokens.count
        let maximumLength = tokens.map { $0.count }.max() ?? 0
        return MLXArray(
            tokens
                .map {
                    $0 + Array(repeating: 0, count: maximumLength - $0.count)
                }
                .flatMap { $0 }
        )
        .reshaped(count, maximumLength)
    }

    func makeConditioning(
        text: String, imageCount: Int, cfgWeight: Float, negativeText: String?
    ) throws -> StableDiffusionConditioning {
        let tokens = tokenize(
            tokenizer: tokenizer, text: text,
            negativeText: cfgWeight > 1 ? negativeText : nil)
        var conditioning = try loadTextEncoder()(tokens).lastHiddenState

        if imageCount > 1 {
            conditioning = repeated(conditioning, count: imageCount, axis: 0)
        }

        return StableDiffusionConditioning(conditioning: conditioning, textTime: nil)
    }

    func conditioning(
        parameters: StableDiffusionEvaluateParameters
    ) throws -> StableDiffusionConditioning {
        let key = StableDiffusionConditioningKey(
            modelID: configuration.id,
            prompt: parameters.prompt,
            negativePrompt: parameters.negativePrompt,
            cfgWeight: parameters.cfgWeight,
            imageCount: parameters.imageCount)
        if let cached = conditioningCache.value(for: key) {
            return cached
        }

        defer {
            if releasesComponentsBetweenStages {
                releaseTextEncoders()
                Memory.clearCache()
            }
        }

        try Task.checkCancellation()
        let conditioning = try makeConditioning(
            text: parameters.prompt, imageCount: parameters.imageCount,
            cfgWeight: parameters.cfgWeight, negativeText: parameters.negativePrompt)
        eval(conditioning.conditioning)
        if let (pooled, timeIDs) = conditioning.textTime {
            eval(pooled, timeIDs)
        }
        try Task.checkCancellation()
        conditioningCache.insert(conditioning, for: key)
        return conditioning
    }

    func makeDenoiser() throws -> StableDiffusionDenoiser {
        let unet = try loadUNet()
        let sampler = self.sampler
        let denoiser = StableDiffusionDenoiser {
            xt, t, tPrev, conditioning, cfgWeight, textTime in
            let xtUNet = cfgWeight > 1 ? concatenated([xt, xt], axis: 0) : xt
            let tUNet = broadcast(t, to: [xtUNet.count])
            var prediction = unet(
                xtUNet, timestep: tUNet, encoderX: conditioning, textTime: textTime)

            if cfgWeight > 1 {
                let (textPrediction, negativePrediction) = prediction.split()
                prediction = negativePrediction
                    + cfgWeight * (textPrediction - negativePrediction)
            }

            return sampler.step(epsPred: prediction, xt: xt, t: t, tPrev: tPrev)
        }

        if releasesComponentsBetweenStages {
            self.unet = nil
        }
        return denoiser
    }

    func makeDenoiseIterator(
        xt: MLXArray, startTime: Int, conditioning: StableDiffusionConditioning,
        parameters: StableDiffusionEvaluateParameters, steps: Int? = nil
    ) throws -> DenoiseIterator {
        let denoiser = try makeDenoiser()
        let timeSteps = sampler.timeSteps(
            steps: steps ?? parameters.steps, start: startTime, dType: dType)
        return DenoiseIterator(
            denoiser: denoiser, xt: xt, conditioning: conditioning.conditioning,
            steps: timeSteps, cfgWeight: parameters.cfgWeight,
            textTime: conditioning.textTime)
    }

    private func decode(_ xt: MLXArray, using autoencoder: Autoencoder) -> MLXArray {
        var raster = autoencoder.decode(xt)
        raster = clip(raster / 2 + 0.5, min: 0, max: 1)
        return raster
    }

    public func detachedDecoder() throws -> ImageDecoder {
        let autoencoder = try loadAutoencoder()
        return { [autoencoder] xt in
            var raster = autoencoder.decode(xt)
            raster = clip(raster / 2 + 0.5, min: 0, max: 1)
            return raster
        }
    }

    public func decode(xt: MLXArray) throws -> MLXArray {
        let autoencoder = try loadAutoencoder()
        defer {
            if releasesComponentsBetweenStages {
                self.autoencoder = nil
                Memory.clearCache()
            }
        }
        let raster = decode(xt, using: autoencoder)
        eval(raster)
        return raster
    }
}

/// Implementation of ``StableDiffusion`` for the `stabilityai/stable-diffusion-2-1-base` model.
open class StableDiffusionBase: StableDiffusion, TextToImageGenerator {

    public init(
        hub: HubApi, configuration: StableDiffusionConfiguration,
        loadConfiguration: LoadConfiguration
    ) throws {
        try super.init(
            hub: hub, configuration: configuration, loadConfiguration: loadConfiguration)
    }

    public func generateLatents(
        parameters: StableDiffusionEvaluateParameters
    ) throws -> DenoiseIterator {
        MLXRandom.seed(parameters.seed)
        let conditioning = try conditioning(parameters: parameters)
        try Task.checkCancellation()
        let xt = sampler.samplePrior(
            shape: [parameters.imageCount] + parameters.latentSize
                + [autoencoderConfiguration.latentChannelsIn],
            dType: dType)
        return try makeDenoiseIterator(
            xt: xt, startTime: sampler.maxTime, conditioning: conditioning,
            parameters: parameters)
    }
}

/// Implementation of ``StableDiffusion`` for the `stabilityai/sdxl-turbo` model.
open class StableDiffusionXL: StableDiffusion, TextToImageGenerator, ImageToImageGenerator {

    var textEncoder2: StableDiffusionTextEncoder?
    let tokenizer2: StableDiffusionTokenizer

    public init(
        hub: HubApi, configuration: StableDiffusionConfiguration,
        loadConfiguration: LoadConfiguration
    ) throws {
        let diffusionConfiguration = try StableDiffusionLoader.loadConfiguration(
            hub: hub, configuration: configuration, key: .diffusionConfig,
            type: DiffusionConfiguration.self)
        let sampler = SimpleEulerAncestralSampler(configuration: diffusionConfiguration)
        self.tokenizer2 = try StableDiffusionLoader.loadTokenizer(
            hub: hub, configuration: configuration, vocabulary: .tokenizerVocabulary2,
            merges: .tokenizerMerges2)

        try super.init(
            hub: hub, configuration: configuration,
            loadConfiguration: loadConfiguration,
            diffusionConfiguration: diffusionConfiguration, sampler: sampler)
    }

    func loadTextEncoder2() throws -> StableDiffusionTextEncoder {
        if let textEncoder2 {
            return textEncoder2
        }
        let textEncoder2 = try loadTextEncoder(
            configKey: .textEncoderConfig2, weightsKey: .textEncoderWeights2)
        self.textEncoder2 = textEncoder2
        return textEncoder2
    }

    open override func ensureLoaded() throws {
        try super.ensureLoaded()
        guard !releasesComponentsBetweenStages else {
            return
        }
        let textEncoder2 = try loadTextEncoder2()
        eval(textEncoder2)
    }

    override func releaseTextEncoders() {
        super.releaseTextEncoders()
        textEncoder2 = nil
    }

    override func makeConditioning(
        text: String, imageCount: Int, cfgWeight: Float, negativeText: String?
    ) throws -> StableDiffusionConditioning {
        let tokens1 = tokenize(
            tokenizer: tokenizer, text: text,
            negativeText: cfgWeight > 1 ? negativeText : nil)
        let tokens2 = tokenize(
            tokenizer: tokenizer2, text: text,
            negativeText: cfgWeight > 1 ? negativeText : nil)

        let conditioning1 = try loadTextEncoder()(tokens1)
        let conditioning2 = try loadTextEncoder2()(tokens2)
        var conditioning = concatenated(
            [
                conditioning1.hiddenStates.dropLast().last!,
                conditioning2.hiddenStates.dropLast().last!,
            ], axis: -1)
        var pooledConditioning = conditioning2.pooledOutput

        if imageCount > 1 {
            conditioning = repeated(conditioning, count: imageCount, axis: 0)
            pooledConditioning = repeated(pooledConditioning, count: imageCount, axis: 0)
        }

        let timeIDs = repeated(
            MLXArray(converting: [512.0, 512, 0, 0, 512, 512]).reshaped(1, -1),
            count: pooledConditioning.count, axis: 0)
        return StableDiffusionConditioning(
            conditioning: conditioning, textTime: (pooledConditioning, timeIDs))
    }

    func conditionImage(image: URL) -> MLXArray {
        guard let imageSource = CGImageSourceCreateWithURL(image as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            fatalError("Could not load image at \(image)")
        }

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let width = originalWidth - (originalWidth % 64)
        let height = originalHeight - (originalHeight % 64)
        var finalCGImage = cgImage

        if width != originalWidth || height != originalHeight {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                fatalError("Could not create CGContext for resizing")
            }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let resizedImage = context.makeImage() else {
                fatalError("Could not create resized CGImage")
            }
            finalCGImage = resizedImage
        }

        let bytesPerPixel = 4
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: &pixelData, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            fatalError("Could not create CGContext for pixel extraction")
        }
        context.draw(finalCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let rawArray = MLXArray(pixelData).reshaped([height, width, 4])
        return (rawArray[0..., 0..., 0..<3].asType(.float32) / 255.0) * 2.0 - 1.0
    }

    public func generateLatents(
        parameters: StableDiffusionEvaluateParameters
    ) throws -> DenoiseIterator {
        MLXRandom.seed(parameters.seed)
        let conditioning = try conditioning(parameters: parameters)
        try Task.checkCancellation()
        let xt = sampler.samplePrior(
            shape: [parameters.imageCount] + parameters.latentSize
                + [autoencoderConfiguration.latentChannelsIn],
            dType: dType)
        return try makeDenoiseIterator(
            xt: xt, startTime: sampler.maxTime, conditioning: conditioning,
            parameters: parameters)
    }

    public func generateLatents(
        image: URL, parameters: StableDiffusionEvaluateParameters, strength: Float
    ) throws -> DenoiseIterator {
        MLXRandom.seed(parameters.seed)
        let image = conditionImage(image: image)
        let startStep = Float(sampler.maxTime) * strength
        let numberOfSteps = Int(Float(parameters.steps) * strength)
        let conditioning = try conditioning(parameters: parameters)

        let autoencoder = try loadAutoencoder()
        var (x0, _) = autoencoder.encode(image[.newAxis])
        x0 = broadcast(x0, to: [parameters.imageCount] + x0.shape.dropFirst())
        eval(x0)
        if releasesComponentsBetweenStages {
            self.autoencoder = nil
            Memory.clearCache()
        }
        try Task.checkCancellation()
        let xt = sampler.addNoise(x: x0, t: MLXArray(startStep))
        return try makeDenoiseIterator(
            xt: xt, startTime: sampler.maxTime, conditioning: conditioning,
            parameters: parameters, steps: numberOfSteps)
    }
}
