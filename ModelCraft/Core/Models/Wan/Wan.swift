//
//  Wan.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import Hub
import CoreGraphics
import ImageIO
import MLX
import MLXNN

public final class Wan {
    public let dtype: DType
    public let vaeStride = (4, 8, 8)
    public let zDim = 16

    public var dit: WanDiT?
    public var vae: WanVAE?
    public var t5: T5Encoder?
    public var tokenizer: T5Tokenizer
    public var clip: CLIPVisionEncoder?
    public var sampler = FlowUniPCMultistepScheduler()

    private var nullContext: MLXArray? = nil
    private var configuration: WanConfiguration
    
    public init(hub: HubApi = HubApi(), configuration: WanConfiguration, dtype: DType = .bfloat16) async throws {
        self.dtype = dtype
        self.configuration = configuration
        self.tokenizer = try await WanLoader.loadTokenizer(configuration: configuration)
    }
    

    public func ensureLoaded() throws {
        var dit: WanDiT {
            get throws {
                if let existing = self.dit {
                    return existing
                }
                let dit = try WanLoader.loadDiT(configuration: configuration)
                self.dit = dit
                return dit
            }
        }
        MLX.eval(try dit.parameters())
        var vae: WanVAE {
            get throws {
                if let existing = self.vae {
                    return existing
                }
                let vae = try WanLoader.loadVAE(configuration: configuration)
                self.vae = vae
                return vae
            }
        }
        MLX.eval(try vae.parameters())
        var t5: T5Encoder {
            get throws {
                if let existing = self.t5 {
                    return existing
                }
                let t5 = try WanLoader.loadT5Encoder(configuration: configuration)
                self.t5 = t5
                return t5
            }
        }
        MLX.eval(try t5.parameters())
        if configuration.ditParameters.modelType == .imageToVideo{
            var clip: CLIPVisionEncoder {
                get throws {
                    if let existing = self.clip {
                        return existing
                    }
                    let clip = try WanLoader.loadCLIP(configuration: configuration)
                    self.clip = clip
                    return clip
                }
            }
            MLX.eval(try clip.parameters())
        }
    }

    private func encodeText(_ text: String) throws -> MLXArray {
        let tokens = try tokenizer.encode(text, maxLength: 512, padding: true, truncation: true)
        var t5: T5Encoder {
            get throws {
                if let existing = self.t5 {
                    return existing
                }
                let t5 = try WanLoader.loadT5Encoder(configuration: configuration)
                self.t5 = t5
                return t5
            }
        }
        let embeddings = try t5(tokens.inputIDs, mask: tokens.attentionMask)
        let seqLen = Int(tokens.attentionMask.sum().item(Int32.self))
        var context = embeddings[0, 0..<max(0, seqLen), 0...]
        if seqLen < 512 {
            let pad = MLX.zeros([512 - seqLen, context.dim(-1)])
            context = MLX.concatenated([context, pad], axis: 0)
        }
        return context
    }

    private func encodeNull() throws -> MLXArray {
        if let nullContext { return nullContext }
        let n = try encodeText("")
        self.nullContext = n
        return n
    }

    private func encodeClip(_ imageURL: URL) throws -> MLXArray {
        guard let clip else { return MLXArray([]) }
        let img = try CLIPImagePreprocess.preprocess(imageURL: imageURL)
        return clip(img).asType(dtype)
    }

    private func conditionImage(_ imageURL: URL, size: (Int, Int), frameNum: Int) throws -> MLXArray {
        let img = try loadImage(imageURL: imageURL, size: size)
        let w = size.0, h = size.1
        let tLatent = (frameNum - 1) / vaeStride.0 + 1
        let hLatent = h / vaeStride.1
        let wLatent = w / vaeStride.2

        let zeros = MLX.zeros([frameNum - 1, h, w, 3])
        let video = MLX.concatenated([img.expandedDimensions(axis: 0), zeros], axis: 0)
        var vae: WanVAE {
            get throws {
                if let existing = self.vae {
                    return existing
                }
                let new = try WanLoader.loadVAE(configuration: configuration)
                self.vae = new
                return new
            }
        }
        let vaeLatent = try vae.encode(video)
        let mskFirst = MLX.ones([1, hLatent, wLatent, 4])
        let mskRest = MLX.zeros([tLatent - 1, hLatent, wLatent, 4])
        let msk = MLX.concatenated([mskFirst, mskRest], axis: 0)
        return MLX.concatenated([msk, vaeLatent], axis: -1).asType(dtype)
    }

    private func loadImage(imageURL: URL, size: (Int, Int)) throws -> MLXArray {
        let targetW = size.0
        let targetH = size.1
        
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "WanPipeline", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }
        
        let iw = cgImage.width
        let ih = cgImage.height
        
        let scale = max(CGFloat(targetW) / CGFloat(iw), CGFloat(targetH) / CGFloat(ih))
        let rw = Int(round(CGFloat(iw) * scale))
        let rh = Int(round(CGFloat(ih) * scale))
        let left = (rw - targetW) / 2
        let top = (rh - targetH) / 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw NSError(domain: "WanPipeline", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: -left, y: -top, width: rw, height: rh))

        guard let pixelData = context.data else {
            throw NSError(domain: "WanPipeline", code: 3, userInfo: [NSLocalizedDescriptionKey: "No pixel data"])
        }
        
        let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
        let totalPixels = targetW * targetH
        var arr = [Float32]()
        arr.reserveCapacity(totalPixels * 3)

        for i in 0..<totalPixels {
            let offset = i * 4
            arr.append((Float32(ptr[offset])     / 127.5) - 1.0) // R
            arr.append((Float32(ptr[offset + 1]) / 127.5) - 1.0) // G
            arr.append((Float32(ptr[offset + 2]) / 127.5) - 1.0) // B
        }

        return MLXArray(arr, [targetH, targetW, 3])
    }

    private func precomputeTeaCache(
        dit: WanDiT,
        scheduler: FlowUniPCMultistepScheduler,
        numSteps: Int,
        threshold: Float
    ) -> ([MLXArray], [MLXArray], [Bool])? {
        let teaCacheConfig = configuration.teaCacheConfig
        let cutoffSteps = teaCacheConfig.useE0 ? numSteps : max(0, numSteps - 1)

        var allTEmb: [MLXArray] = []
        var allE0: [MLXArray] = []
        allTEmb.reserveCapacity(numSteps)
        allE0.reserveCapacity(numSteps)
        
        for t in scheduler.timesteps {
            let tVal = MLXArray([Float32(t.item(Int32.self))]).asType(.float32)
            let (tEmb, e0) = dit.computeTimeEmbedding(tVal)
            allTEmb.append(tEmb)
            allE0.append(e0)
        }

        var rescaled: [Float] = []
        if numSteps > 1 {
            for i in 1..<numSteps {
                let cur = teaCacheConfig.useE0 ? allE0[i] : allTEmb[i]
                let prev = teaCacheConfig.useE0 ? allE0[i - 1] : allTEmb[i - 1]
                let num = MLX.abs(cur - prev).mean().item(Float.self)
                let den = MLX.abs(prev).mean().item(Float.self) + 1e-8
                let d = Double(num / den)
                var p = teaCacheConfig.coeffs[0]
                for c in teaCacheConfig.coeffs.dropFirst() {
                    p = p * d + c
                }
                rescaled.append(Float(abs(p)))
            }
        }

        var skipMask: [Bool] = []
        skipMask.reserveCapacity(numSteps)
        var accum: Float = 0
        for step in 0..<numSteps {
            let mustCompute = step < teaCacheConfig.retSteps || step >= cutoffSteps || step == 0
            if !mustCompute && step - 1 < rescaled.count {
                accum += rescaled[step - 1]
            }
            let shouldSkip = !mustCompute && accum < threshold
            skipMask.append(shouldSkip)
            if !shouldSkip {
                accum = 0
            }
        }

        return (allTEmb, allE0, skipMask)
    }

    public func generateLatents(_ req: WanEvaluateParameters) throws -> AsyncStream<MLXArray> {
        var teaThreshold = req.teacache
        if req.denoisingStepList != nil && teaThreshold > 0 {
            teaThreshold = 0
        }
        if let seed = req.seed { MLXRandom.seed(seed) }
        let w = req.size.0, h = req.size.1
        let targetShape: [Int] = [
            (req.frameNum - 1) / vaeStride.0 + 1,
            h / vaeStride.1,
            w / vaeStride.2,
            zDim,
        ]
        let context = try encodeText(req.prompt)
        let contextNull = req.negativePrompt.isEmpty ? try encodeNull() : try encodeText(req.negativePrompt)
        MLX.eval(context, contextNull)
        self.t5 = nil
        Memory.clearCache()
        
        var clipFeatures: MLXArray? = nil
        var firstFrame: MLXArray? = nil
        if let url = req.imageURL, clip != nil {
            clipFeatures = try encodeClip(url)
            firstFrame = try conditionImage(url, size: req.size, frameNum: req.frameNum)
            MLX.eval(clipFeatures, firstFrame)
        }
        self.clip = nil
        self.vae = nil
        Memory.clearCache()
        
        var x = MLXRandom.normal(targetShape).asType(dtype)
        MLX.eval(x)
        
        if self.dit == nil {
            self.dit = try WanLoader.loadDiT(configuration: configuration)
        }
        
        return AsyncStream { continuation in
            
            guard let dit = self.dit else {
                continuation.finish()
                return
            }
            if req.quantizeBits == 4 || req.quantizeBits == 8 {
                MLXNN.quantize(model: dit, bits: req.quantizeBits)
            }
            let task = Task {
                defer {
                    self.cleanup()
                    continuation.finish()
                }
                
                if let denoise = req.denoisingStepList {
                    var sampler = FlowEulerDiscreteScheduler()
                    sampler.setTimesteps(denoise, shift: req.shift)
                    for t in denoise {
                        let tVal = MLXArray([Float32(t)])
                        let cond = dit(x, t: tVal, context: context, clipFea: clipFeatures, firstFrame: firstFrame).output
                        let noise: MLXArray
                        if req.guidance > 1.0 {
                            let uncond = dit(x, t: tVal, context: contextNull, clipFea: clipFeatures, firstFrame: firstFrame).output
                            noise = uncond + req.guidance * (cond - uncond)
                        } else {
                            noise = cond
                        }
                        x = sampler.step(modelOutput: noise, timestep: tVal, sample: x)
                        MLX.eval(x)
                        continuation.yield(x)
                    }
                } else {
                    var sampler = sampler
                    sampler.setTimesteps(req.numSteps, shift: req.shift)
                    let ts = sampler.timesteps
                    var prevResidualCond: MLXArray? = nil
                    var prevResidualUncond: MLXArray? = nil
                    var allTEmb: [MLXArray] = []
                    var allE0: [MLXArray] = []
                    var skipMask: [Bool] = []
                    let useTea = teaThreshold > 0
                    if useTea, let precomputed = precomputeTeaCache(
                        dit: dit,
                        scheduler: sampler,
                        numSteps: req.numSteps,
                        threshold: teaThreshold
                    ) {
                        allTEmb = precomputed.0
                        allE0 = precomputed.1
                        skipMask = precomputed.2
                    }
                    
                    for i in 0..<Int(ts.shape[0]) {
                        let tVal = ts[i].reshaped([1]).asType(.float32)
                        
                        let cond: MLXArray
                        if useTea && !skipMask.isEmpty {
                            let precomputed = (allTEmb[i], allE0[i])
                            if skipMask[i], let res = prevResidualCond {
                                cond = dit(x, t: tVal, context: context, blockResidual: res, precomputedTime: precomputed, clipFea: clipFeatures, firstFrame: firstFrame).output
                            } else {
                                let out = dit(x, t: tVal, context: context, precomputedTime: precomputed, clipFea: clipFeatures, firstFrame: firstFrame)
                                cond = out.output
                                prevResidualCond = out.residual
                                MLX.eval(prevResidualCond!)
                            }
                        } else {
                            cond = dit(x, t: tVal, context: context, clipFea: clipFeatures, firstFrame: firstFrame).output
                        }
                        
                        let noisePred: MLXArray
                        if req.guidance > 1.0 {
                            let uncond: MLXArray
                            if useTea && !skipMask.isEmpty {
                                let precomputed = (allTEmb[i], allE0[i])
                                if skipMask[i], let resUncond = prevResidualUncond {
                                    uncond = dit(x, t: tVal, context: contextNull, blockResidual: resUncond, precomputedTime: precomputed, clipFea: clipFeatures, firstFrame: firstFrame).output
                                } else {
                                    let out = dit(x, t: tVal, context: contextNull, precomputedTime: precomputed, clipFea: clipFeatures, firstFrame: firstFrame)
                                    uncond = out.output
                                    prevResidualUncond = out.residual
                                    MLX.eval(prevResidualUncond!)
                                }
                            } else {
                                uncond = dit(x, t: tVal, context: contextNull, clipFea: clipFeatures, firstFrame: firstFrame).output
                            }
                            noisePred = uncond + (req.guidance) * (cond - uncond)
                        } else {
                            noisePred = cond
                        }
                        
                        x = sampler.step(modelOutput: noisePred, timestep: tVal, sample: x)
                        MLX.eval(x)
                        continuation.yield(x)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.cleanup()
            }
        }
    }

    public func decode(_ latents: MLXArray) throws -> MLXArray {
        var vae: WanVAE {
            get throws {
                if let existing = self.vae {
                    return existing
                }
                let new = try WanLoader.loadVAE(configuration: configuration)
                self.vae = new
                return new
            }
        }
        return try vae.decode(latents)
    }
    
    private func cleanup() {
        self.dit = nil
        self.t5 = nil
        self.clip = nil
        self.vae = nil
        Memory.clearCache()
    }
}

public struct WanEvaluateParameters {
    public var prompt: String = ""
    public var imageURL: URL? = nil
    public var negativePrompt: String = "Text, watermarks, blurry image, JPEG artifacts"
    public var size: (Int, Int) = (832, 480)
    public var frameNum: Int = 81
    public var numSteps: Int = 50
    public var guidance: Float = 5.0
    public var shift: Float = 5.0
    public var seed: UInt64? = nil
    public var teacache: Float = 0.0
    public var denoisingStepList: [Int]? = nil
    public var quantizeBits: Int = 0
}

struct TeaCacheConfig {
    let coeffs: [Double]
    let retSteps: Int
    let useE0: Bool
}


enum WanFileKey {
    case tokenizer
    case vaeWeights
    case ditWeights
    case t5Weihghts
    case clipWeights
}

public struct WanDitParameters: Codable, Sendable {

    public var dim: Int
    public var ffnDim: Int
    public var numHeads: Int
    public var numLayers: Int
    public var inDim: Int? = nil
    public var modelType: ModelType

}

public struct WanConfiguration: Sendable {
    
    public var id: String
    let files: [WanFileKey: String]
    let ditParameters: WanDitParameters
    let teaCacheConfig: TeaCacheConfig
    public let defaultParameters: @Sendable () -> WanEvaluateParameters

    public func download(
        hub: HubApi = HubApi(), progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let repo = Hub.Repo(id: self.id)
        try await hub.snapshot(
            from: repo, matching: Array(files.values), progressHandler: progressHandler)
    }
    
    public static let presetT2V1_3B = WanConfiguration(
        id: "Wan-AI/Wan2.1-T2V-1.3B",
        files: [
            .ditWeights: "diffusion_pytorch_model.safetensors",
            .vaeWeights: "Wan2.1_VAE.pth",
            .t5Weihghts: "models_t5_umt5-xxl-enc-bf16.pth",
            .tokenizer: "google/umt5-xxl/tokenizer.json",
        ],
        ditParameters: WanDitParameters(dim: 1536, ffnDim: 8960, numHeads: 12,
                                        numLayers: 30, modelType: .textToVideo),
        teaCacheConfig: TeaCacheConfig(
            coeffs: [-5.21862437e04, 9.23041404e03, -5.28275948e02, 1.36987616e01, -4.99875664e-02],
            retSteps: 5,
            useE0: true
        ),
        defaultParameters: { WanEvaluateParameters() },
    )
    
    public static let presetT2V14B = WanConfiguration(
        id: "Wan-AI/Wan2.1-T2V-14B",
        files: [
            .ditWeights: "diffusion_pytorch_model.safetensors.index.json",
            .vaeWeights: "Wan2.1_VAE.pth",
            .t5Weihghts: "models_t5_umt5-xxl-enc-bf16.pth",
            .tokenizer: "google/umt5-xxl/tokenizer.json",
        ],
        ditParameters: WanDitParameters(dim: 5120, ffnDim: 13824, numHeads: 40,
                                        numLayers: 40, modelType: .textToVideo),
        teaCacheConfig: TeaCacheConfig(
            coeffs: [-5784.54975374, 5449.50911966, -1811.16591783, 256.27178429, -13.02252404],
            retSteps: 1,
            useE0: false
        ),
        defaultParameters: { WanEvaluateParameters() },
    )
    
    public static let presetI2V14B = WanConfiguration(
        id: "Wan-AI/Wan2.1-I2V-14B-480P",
        files: [
            .ditWeights: "diffusion_pytorch_model.safetensors.index.json",
            .vaeWeights: "Wan2.1_VAE.pth",
            .t5Weihghts: "models_t5_umt5-xxl-enc-bf16.pth",
            .tokenizer: "google/umt5-xxl/tokenizer.json",
            .clipWeights: "models_clip_open-clip-xlm-roberta-large-vit-huge-14.pth"
        ],
        ditParameters: WanDitParameters(dim: 5120, ffnDim: 13824, numHeads: 40, numLayers: 40,
                                        inDim: 36, modelType: .imageToVideo),
        teaCacheConfig: TeaCacheConfig(
            coeffs: [2.57151496e05, -3.54229917e04, 1.40286849e03, -1.35890334e01, 1.32517977e-01],
            retSteps: 5,
            useE0: true
        ),
        defaultParameters: { WanEvaluateParameters() },
    )
}
