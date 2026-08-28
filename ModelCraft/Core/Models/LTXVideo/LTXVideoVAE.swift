//
//  LTXVideoVAE.swift
//  ModelCraft
//

import Foundation

import MLX
import MLXNN

public final class LTXVideoConv3d: Module {
    public let kernelSize: (Int, Int, Int)
    public let stride: (Int, Int, Int)
    public let isCausal: Bool
    public var weight: MLXArray
    public var bias: MLXArray?

    public init(
        inChannels: Int,
        outChannels: Int,
        kernelSize: (Int, Int, Int) = (3, 3, 3),
        stride: (Int, Int, Int) = (1, 1, 1),
        isCausal: Bool,
        bias: Bool = true
    ) {
        self.kernelSize = kernelSize
        self.stride = stride
        self.isCausal = isCausal
        let scale = 1.0 / sqrt(Float(inChannels * kernelSize.0 * kernelSize.1 * kernelSize.2))
        self.weight = MLXRandom.uniform(
            low: -scale,
            high: scale,
            [outChannels, kernelSize.0, kernelSize.1, kernelSize.2, inChannels]
        )
        self.bias = bias ? MLX.zeros([outChannels]) : nil
    }

    public func callAsFunction(_ xIn: MLXArray) -> MLXArray {
        var x = xIn
        let timePadLeft: Int
        let timePadRight: Int
        if isCausal {
            timePadLeft = kernelSize.0 - 1
            timePadRight = 0
        } else {
            timePadLeft = (kernelSize.0 - 1) / 2
            timePadRight = (kernelSize.0 - 1) / 2
        }

        if timePadLeft > 0 || timePadRight > 0 {
            let first = x[0..., 0..<1, 0..., 0..., 0...]
            let last = x[0..., (x.shape[1] - 1)..<x.shape[1], 0..., 0..., 0...]
            var chunks: [MLXArray] = []
            if timePadLeft > 0 {
                chunks.append(broadcast(first, to: [x.shape[0], timePadLeft, x.shape[2], x.shape[3], x.shape[4]]))
            }
            chunks.append(x)
            if timePadRight > 0 {
                chunks.append(broadcast(last, to: [x.shape[0], timePadRight, x.shape[2], x.shape[3], x.shape[4]]))
            }
            x = MLX.concatenated(chunks, axis: 1)
        }

        let spatialPadH = kernelSize.1 / 2
        let spatialPadW = kernelSize.2 / 2
        if spatialPadH > 0 || spatialPadW > 0 {
            x = MLX.padded(
                x,
                widths: [
                    .init(arrayLiteral: 0, 0),
                    .init(arrayLiteral: 0, 0),
                    .init(arrayLiteral: spatialPadH, spatialPadH),
                    .init(arrayLiteral: spatialPadW, spatialPadW),
                    .init(arrayLiteral: 0, 0),
                ]
            )
        }

        var y = MLX.conv3d(x, weight, stride: .init(stride), padding: 0)
        if let bias {
            y = y + bias
        }
        return y
    }
}

public final class LTXVideoResnetBlock3D: Module {
    @ModuleInfo var norm1: RMSNorm
    @ModuleInfo var norm2: RMSNorm
    @ModuleInfo var conv1: LTXVideoConv3d
    @ModuleInfo var conv2: LTXVideoConv3d
    @ModuleInfo var norm3: LayerNorm?
    @ModuleInfo(key: "conv_shortcut") var convShortcut: LTXVideoConv3d?

    public init(inChannels: Int, outChannels: Int, isCausal: Bool) {
        self._norm1.wrappedValue = RMSNorm(dimensions: inChannels, eps: 1e-8)
        self._norm2.wrappedValue = RMSNorm(dimensions: outChannels, eps: 1e-8)
        self._conv1.wrappedValue = LTXVideoConv3d(
            inChannels: inChannels,
            outChannels: outChannels,
            kernelSize: (3, 3, 3),
            isCausal: isCausal
        )
        self._conv2.wrappedValue = LTXVideoConv3d(
            inChannels: outChannels,
            outChannels: outChannels,
            kernelSize: (3, 3, 3),
            isCausal: isCausal
        )
        if inChannels == outChannels {
            self._norm3.wrappedValue = nil
            self._convShortcut.wrappedValue = nil
        } else {
            self._norm3.wrappedValue = LayerNorm(dimensions: inChannels, eps: 1e-6)
            self._convShortcut.wrappedValue = LTXVideoConv3d(
                inChannels: inChannels,
                outChannels: outChannels,
                kernelSize: (1, 1, 1),
                isCausal: isCausal
            )
        }
    }

    public func callAsFunction(_ input: MLXArray) -> MLXArray {
        var x = MLXNN.silu(norm1(input))
        x = conv1(x)
        x = MLXNN.silu(norm2(x))
        x = conv2(x)
        let shortcut = convShortcut?(norm3?(input) ?? input) ?? input
        return x + shortcut
    }
}

public final class LTXVideoUpsampler3D: Module {
    public let stride: (Int, Int, Int)
    public let residual: Bool
    public let upscaleFactor: Int
    @ModuleInfo var conv: LTXVideoConv3d

    public init(
        channels: Int,
        stride: (Int, Int, Int) = (2, 2, 2),
        isCausal: Bool,
        residual: Bool = false,
        upscaleFactor: Int = 1
    ) {
        self.stride = stride
        self.residual = residual
        self.upscaleFactor = upscaleFactor
        let outChannels = channels * stride.0 * stride.1 * stride.2 / upscaleFactor
        self._conv.wrappedValue = LTXVideoConv3d(
            inChannels: channels,
            outChannels: outChannels,
            kernelSize: (3, 3, 3),
            isCausal: isCausal
        )
    }

    public func callAsFunction(_ input: MLXArray) -> MLXArray {
        let b = Int(input.shape[0])
        let t = Int(input.shape[1])
        let h = Int(input.shape[2])
        let w = Int(input.shape[3])
        var residualValue: MLXArray?

        if residual {
            let c = Int(input.shape[4]) / (stride.0 * stride.1 * stride.2)
            residualValue = input
                .reshaped([b, t, h, w, c, stride.0, stride.1, stride.2])
                .transposed(0, 1, 5, 2, 6, 3, 7, 4)
                .reshaped([b, t * stride.0, h * stride.1, w * stride.2, c])
            if stride.0 > 1 {
                residualValue = residualValue![0..., (stride.0 - 1)..., 0..., 0..., 0...]
            }
        }

        var x = conv(input)
        let cOut = Int(x.shape[4]) / (stride.0 * stride.1 * stride.2)
        x = x
            .reshaped([b, t, h, w, cOut, stride.0, stride.1, stride.2])
            .transposed(0, 1, 5, 2, 6, 3, 7, 4)
            .reshaped([b, t * stride.0, h * stride.1, w * stride.2, cOut])

        if stride.0 > 1 {
            x = x[0..., (stride.0 - 1)..., 0..., 0..., 0...]
        }
        if let residualValue {
            x = x + residualValue
        }
        return x
    }
}

public final class LTXVideoMidBlock3D: Module {
    @ModuleInfo var resnets: [LTXVideoResnetBlock3D]

    public init(channels: Int, layerCount: Int, isCausal: Bool) {
        self._resnets.wrappedValue = (0..<layerCount).map { _ in
            LTXVideoResnetBlock3D(inChannels: channels, outChannels: channels, isCausal: isCausal)
        }
    }

    public func callAsFunction(_ input: MLXArray) -> MLXArray {
        var x = input
        for resnet in resnets {
            x = resnet(x)
        }
        return x
    }
}

public final class LTXVideoUpBlock3D: Module {
    @ModuleInfo(key: "conv_in") var convIn: LTXVideoResnetBlock3D?
    @ModuleInfo var upsamplers: [LTXVideoUpsampler3D]
    @ModuleInfo var resnets: [LTXVideoResnetBlock3D]

    public init(
        inChannels: Int,
        outChannels: Int,
        layerCount: Int,
        spatioTemporalScale: Bool,
        isCausal: Bool,
        upsampleResidual: Bool,
        upscaleFactor: Int
    ) {
        self._convIn.wrappedValue = inChannels == outChannels
            ? nil
            : LTXVideoResnetBlock3D(inChannels: inChannels, outChannels: outChannels, isCausal: isCausal)
        self._upsamplers.wrappedValue = spatioTemporalScale
            ? [LTXVideoUpsampler3D(
                channels: outChannels * upscaleFactor,
                isCausal: isCausal,
                residual: upsampleResidual,
                upscaleFactor: upscaleFactor
            )]
            : []
        self._resnets.wrappedValue = (0..<layerCount).map { _ in
            LTXVideoResnetBlock3D(inChannels: outChannels, outChannels: outChannels, isCausal: isCausal)
        }
    }

    public func callAsFunction(_ input: MLXArray) -> MLXArray {
        var x = convIn?(input) ?? input
        for upsampler in upsamplers {
            x = upsampler(x)
        }
        for resnet in resnets {
            x = resnet(x)
        }
        return x
    }
}

public final class LTXVideoDecoder3D: Module {
    public let patchSize: Int
    public let patchSizeT: Int
    public let outputChannels: Int

    @ModuleInfo(key: "conv_in") var convIn: LTXVideoConv3d
    @ModuleInfo(key: "mid_block") var midBlock: LTXVideoMidBlock3D
    @ModuleInfo(key: "up_blocks") var upBlocks: [LTXVideoUpBlock3D]
    @ModuleInfo(key: "norm_out") var normOut: RMSNorm
    @ModuleInfo(key: "conv_out") var convOut: LTXVideoConv3d

    public init(configuration: LTXVideoVAEConfiguration, isCausal: Bool = false) {
        self.patchSize = configuration.patchSize
        self.patchSizeT = configuration.patchSizeT
        self.outputChannels = 3

        let blockOut = Array(configuration.blockOutChannels.reversed())
        let scaling = Array(configuration.spatioTemporalScaling.reversed())
        let layers = Array(configuration.layersPerBlock.reversed())
        let outputChannel = blockOut[0]

        self._convIn.wrappedValue = LTXVideoConv3d(
            inChannels: configuration.latentChannels,
            outChannels: outputChannel,
            kernelSize: (3, 3, 3),
            isCausal: isCausal
        )
        self._midBlock.wrappedValue = LTXVideoMidBlock3D(
            channels: outputChannel,
            layerCount: layers[0],
            isCausal: isCausal
        )

        var current = outputChannel
        var blocks: [LTXVideoUpBlock3D] = []
        for i in 0..<blockOut.count {
            let inputChannel = current
            current = blockOut[i]
            blocks.append(
                LTXVideoUpBlock3D(
                    inChannels: inputChannel,
                    outChannels: current,
                    layerCount: layers[i + 1],
                    spatioTemporalScale: scaling[i],
                    isCausal: isCausal,
                    upsampleResidual: false,
                    upscaleFactor: 1
                )
            )
        }
        self._upBlocks.wrappedValue = blocks
        self._normOut.wrappedValue = RMSNorm(dimensions: current, eps: 1e-8)
        self._convOut.wrappedValue = LTXVideoConv3d(
            inChannels: current,
            outChannels: outputChannels * patchSize * patchSize * patchSizeT,
            kernelSize: (3, 3, 3),
            isCausal: isCausal
        )
    }

    public func callAsFunction(_ input: MLXArray) -> MLXArray {
        var x = convIn(input)
        x = midBlock(x)
        for block in upBlocks {
            x = block(x)
        }
        x = MLXNN.silu(normOut(x))
        x = convOut(x)

        let b = Int(x.shape[0])
        let f = Int(x.shape[1])
        let h = Int(x.shape[2])
        let w = Int(x.shape[3])
        return x
            .reshaped([b, f, h, w, outputChannels, patchSizeT, patchSize, patchSize])
            .transposed(0, 1, 5, 2, 6, 3, 7, 4)
            .reshaped([b, f * patchSizeT, h * patchSize, w * patchSize, outputChannels])
    }
}

public final class LTXVideoVAE: Module {
    public let configuration: LTXVideoVAEConfiguration
    @ModuleInfo var decoder: LTXVideoDecoder3D
    public var latentsMean: MLXArray
    public var latentsStd: MLXArray

    public init(configuration: LTXVideoVAEConfiguration) {
        self.configuration = configuration
        self._decoder.wrappedValue = LTXVideoDecoder3D(configuration: configuration)
        self.latentsMean = MLX.zeros([configuration.latentChannels])
        self.latentsStd = MLX.ones([configuration.latentChannels])
    }

    public func decode(_ latents: MLXArray) -> MLXArray {
        decoder(latents)
    }

    public func denormalize(_ latents: MLXArray) -> MLXArray {
        let mean = latentsMean.reshaped([1, 1, 1, 1, -1]).asType(latents.dtype)
        let std = latentsStd.reshaped([1, 1, 1, 1, -1]).asType(latents.dtype)
        return latents * std / configuration.scalingFactor + mean
    }

    public static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var result: [String: MLXArray] = [:]
        for (rawKey, valueIn) in weights {
            var key = rawKey
            var value = valueIn
            if key.hasPrefix("vae.") {
                key.removeFirst("vae.".count)
            }
            if key.hasPrefix("decoder.") {
                key = "decoder." + String(key.dropFirst("decoder.".count))
            } else if !key.hasPrefix("decoder.") && !key.hasPrefix("latents_") {
                continue
            }

            key = key.replacingOccurrences(of: ".conv.", with: ".")
            key = key.replacingOccurrences(of: "conv_shortcut.", with: "conv_shortcut.")
            key = key.replacingOccurrences(of: "latents_mean", with: "latentsMean")
            key = key.replacingOccurrences(of: "latents_std", with: "latentsStd")

            if key.hasSuffix(".weight"), Int(value.ndim) == 5 {
                value = value.transposed(0, 2, 3, 4, 1)
            }
            result[key] = value
        }
        return result
    }
}
