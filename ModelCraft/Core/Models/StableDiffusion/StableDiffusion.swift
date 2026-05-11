// Copyright © 2024 Apple Inc.

import Foundation
import CoreGraphics
import ImageIO
import Hub
import MLX
import MLXNN


/// Base class for Stable Diffusion.
open class StableDiffusion {

    let dType: DType
    let diffusionConfiguration: DiffusionConfiguration
    let unet: StableDiffusionUNet
    let textEncoder: StableDiffusionTextEncoder
    let autoencoder: Autoencoder
    let sampler: SimpleEulerSampler
    let tokenizer: StableDiffusionTokenizer

    internal init(
        hub: HubApi, configuration: StableDiffusionConfiguration, dType: DType,
        diffusionConfiguration: DiffusionConfiguration? = nil, unet: StableDiffusionUNet? = nil,
        textEncoder: StableDiffusionTextEncoder? = nil, autoencoder: Autoencoder? = nil,
        sampler: SimpleEulerSampler? = nil, tokenizer: StableDiffusionTokenizer? = nil
    ) throws {
        self.dType = dType
        self.diffusionConfiguration =
            try diffusionConfiguration
        ?? StableDiffusionLoader.loadDiffusionConfiguration(hub: hub, configuration: configuration)
        self.unet = try unet ?? StableDiffusionLoader.loadUnet(hub: hub, configuration: configuration, dType: dType)
        self.textEncoder =
        try textEncoder ?? StableDiffusionLoader.loadTextEncoder(hub: hub, configuration: configuration, dType: dType)

        // note: autoencoder uses float32 weights
        self.autoencoder =
            try autoencoder
        ?? StableDiffusionLoader.loadAutoEncoder(hub: hub, configuration: configuration, dType: .float32)

        if let sampler {
            self.sampler = sampler
        } else {
            self.sampler = SimpleEulerSampler(configuration: self.diffusionConfiguration)
        }
        self.tokenizer = try tokenizer ?? StableDiffusionLoader.loadTokenizer(hub: hub, configuration: configuration)
    }

    open func ensureLoaded() {
        eval(unet, textEncoder, autoencoder)
    }

    func tokenize(tokenizer: StableDiffusionTokenizer, text: String, negativeText: String?) -> MLXArray {
        var tokens = [tokenizer.tokenize(text: text)]
        if let negativeText {
            tokens.append(tokenizer.tokenize(text: negativeText))
        }

        let c = tokens.count
        let max = tokens.map { $0.count }.max() ?? 0
        let mlxTokens = MLXArray(
            tokens
                .map {
                    ($0 + Array(repeating: 0, count: max - $0.count))
                }
                .flatMap { $0 }
        )
        .reshaped(c, max)

        return mlxTokens
    }

    open func step(
        xt: MLXArray, t: MLXArray, tPrev: MLXArray, conditioning: MLXArray, cfgWeight: Float,
        textTime: (MLXArray, MLXArray)?
    ) -> MLXArray {
        let xtUnet = cfgWeight > 1 ? concatenated([xt, xt], axis: 0) : xt
        let tUnet = broadcast(t, to: [xtUnet.count])

        var epsPred = unet(xtUnet, timestep: tUnet, encoderX: conditioning, textTime: textTime)

        if cfgWeight > 1 {
            let (epsText, epsNeg) = epsPred.split()
            epsPred = epsNeg + cfgWeight * (epsText - epsNeg)
        }

        return sampler.step(epsPred: epsPred, xt: xt, t: t, tPrev: tPrev)
    }

    public func detachedDecoder() -> ImageDecoder {
        let autoencoder = self.autoencoder
        func decode(xt: MLXArray) -> MLXArray {
            var x = autoencoder.decode(xt)
            x = clip(x / 2 + 0.5, min: 0, max: 1)
            return x
        }
        return decode(xt:)
    }

    public func decode(xt: MLXArray) -> MLXArray {
        detachedDecoder()(xt)
    }
}

/// Implementation of ``StableDiffusion`` for the `stabilityai/stable-diffusion-2-1-base` model.
open class StableDiffusionBase: StableDiffusion, TextToImageGenerator {

    public init(hub: HubApi, configuration: StableDiffusionConfiguration, dType: DType) throws {
        try super.init(hub: hub, configuration: configuration, dType: dType)
    }

    func conditionText(text: String, imageCount: Int, cfgWeight: Float, negativeText: String?)
        -> MLXArray
    {
        // tokenize the text
        let tokens = tokenize(
            tokenizer: tokenizer, text: text, negativeText: cfgWeight > 1 ? negativeText : nil)

        // compute the features
        var conditioning = textEncoder(tokens).lastHiddenState

        // repeat the conditioning for each of the generated images
        if imageCount > 1 {
            conditioning = repeated(conditioning, count: imageCount, axis: 0)
        }

        return conditioning
    }

    public func generateLatents(parameters: StableDiffusionEvaluateParameters) -> DenoiseIterator {
        MLXRandom.seed(parameters.seed)

        let conditioning = conditionText(
            text: parameters.prompt, imageCount: parameters.imageCount,
            cfgWeight: parameters.cfgWeight, negativeText: parameters.negativePrompt)

        let xt = sampler.samplePrior(
            shape: [parameters.imageCount] + parameters.latentSize + [autoencoder.latentChannels],
            dType: dType)

        return DenoiseIterator(
            sd: self, xt: xt, t: sampler.maxTime, conditioning: conditioning,
            steps: parameters.steps, cfgWeight: parameters.cfgWeight)
    }

}

/// Implementation of ``StableDiffusion`` for the `stabilityai/sdxl-turbo` model.
open class StableDiffusionXL: StableDiffusion, TextToImageGenerator, ImageToImageGenerator {

    let textEncoder2: StableDiffusionTextEncoder
    let tokenizer2: StableDiffusionTokenizer

    public init(hub: HubApi, configuration: StableDiffusionConfiguration, dType: DType) throws {
        let diffusionConfiguration = try StableDiffusionLoader.loadConfiguration(
            hub: hub, configuration: configuration, key: .diffusionConfig,
            type: DiffusionConfiguration.self)
        let sampler = SimpleEulerAncestralSampler(configuration: diffusionConfiguration)

        self.textEncoder2 = try StableDiffusionLoader.loadTextEncoder(
            hub: hub, configuration: configuration, configKey: .textEncoderConfig2,
            weightsKey: .textEncoderWeights2, dType: dType)

        self.tokenizer2 = try StableDiffusionLoader.loadTokenizer(
            hub: hub, configuration: configuration, vocabulary: .tokenizerVocabulary2,
            merges: .tokenizerMerges2)

        try super.init(
            hub: hub, configuration: configuration, dType: dType,
            diffusionConfiguration: diffusionConfiguration, sampler: sampler)
    }

    open override func ensureLoaded() {
        super.ensureLoaded()
        eval(textEncoder2)
    }

    func conditionText(text: String, imageCount: Int, cfgWeight: Float, negativeText: String?) -> (
        MLXArray, MLXArray
    ) {
        let tokens1 = tokenize(
            tokenizer: tokenizer, text: text, negativeText: cfgWeight > 1 ? negativeText : nil)
        let tokens2 = tokenize(
            tokenizer: tokenizer2, text: text, negativeText: cfgWeight > 1 ? negativeText : nil)

        let conditioning1 = textEncoder(tokens1)
        let conditioning2 = textEncoder2(tokens2)
        var conditioning = concatenated(
            [
                conditioning1.hiddenStates.dropLast().last!,
                conditioning2.hiddenStates.dropLast().last!,
            ],
            axis: -1)
        var pooledConditionng = conditioning2.pooledOutput

        if imageCount > 1 {
            conditioning = repeated(conditioning, count: imageCount, axis: 0)
            pooledConditionng = repeated(pooledConditionng, count: imageCount, axis: 0)
        }

        return (conditioning, pooledConditionng)
    }
    
    
    func conditionImage(image: URL) -> MLXArray {
        guard let imageSource = CGImageSourceCreateWithURL(image as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            fatalError("Could not load image at \(image)")
        }

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height

        let width = originalWidth - (originalWidth % 64)
        let height = originalHeight - (originalHeight % 64)
        
        var finalCGImage: CGImage = cgImage

        if width != originalWidth || height != originalHeight {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
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
        
        guard let context = CGContext(data: &pixelData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * bytesPerPixel,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not create CGContext for pixel extraction")
        }
        
        context.draw(finalCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let rawArray = MLXArray(pixelData).reshaped([height, width, 4])
        let img = (rawArray[0..., 0..., 0..<3].asType(.float32) / 255.0) * 2.0 - 1.0
        
        return img
    }
    
    public func generateLatents(parameters: StableDiffusionEvaluateParameters) -> DenoiseIterator {
        MLXRandom.seed(parameters.seed)

        let (conditioning, pooledConditioning) = conditionText(
            text: parameters.prompt, imageCount: parameters.imageCount,
            cfgWeight: parameters.cfgWeight, negativeText: parameters.negativePrompt)

        let textTime = (
            pooledConditioning,
            repeated(
                MLXArray(converting: [512.0, 512, 0, 0, 512, 512]).reshaped(1, -1),
                count: pooledConditioning.count, axis: 0)
        )

        let xt = sampler.samplePrior(
            shape: [parameters.imageCount] + parameters.latentSize + [autoencoder.latentChannels],
            dType: dType)

        return DenoiseIterator(
            sd: self, xt: xt, t: sampler.maxTime, conditioning: conditioning,
            steps: parameters.steps, cfgWeight: parameters.cfgWeight, textTime: textTime)
    }
    
    
    
    public func generateLatents(image: URL, parameters: StableDiffusionEvaluateParameters, strength: Float)
        -> DenoiseIterator
    {
        MLXRandom.seed(parameters.seed)
        let image = conditionImage(image: image)
        // Define the num steps and start step
        let startStep = Float(sampler.maxTime) * strength
        let numSteps = Int(Float(parameters.steps) * strength)

        let (conditioning, pooledConditioning) = conditionText(
            text: parameters.prompt, imageCount: parameters.imageCount,
            cfgWeight: parameters.cfgWeight, negativeText: parameters.negativePrompt)

        let textTime = (
            pooledConditioning,
            repeated(
                MLXArray(converting: [512.0, 512, 0, 0, 512, 512]).reshaped(1, -1),
                count: pooledConditioning.count, axis: 0)
        )

        // Get the latents from the input image and add noise according to the
        // start time.

        var (x0, _) = autoencoder.encode(image[.newAxis])
        x0 = broadcast(x0, to: [parameters.imageCount] + x0.shape.dropFirst())
        let xt = sampler.addNoise(x: x0, t: MLXArray(startStep))

        return DenoiseIterator(
            sd: self, xt: xt, t: sampler.maxTime, conditioning: conditioning, steps: numSteps,
            cfgWeight: parameters.cfgWeight, textTime: textTime)
    }
}
