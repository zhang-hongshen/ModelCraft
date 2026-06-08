// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXNN
import MLXFast

// MARK: - Encodec Model

public class MusicGenAudioDecoder: Module {
    let config: MusicGenAudioEncoderParameters
    @ModuleInfo var decoder: EncodecDecoder
    @ModuleInfo var quantizer: EncodecResidualVectorQuantizer

    public init(config: MusicGenAudioEncoderParameters) {
        self.config = config
        self._decoder.wrappedValue = EncodecDecoder(config: config)
        self._quantizer.wrappedValue = EncodecResidualVectorQuantizer(config: config)
    }

    var channels: Int { config.audioChannels }
    var samplingRate: Int { config.samplingRate }

    var chunkLength: Int? {
        guard let chunkLengthS = config.chunkLengthS else { return nil }
        return Int(chunkLengthS * Float(config.samplingRate))
    }

    var chunkStride: Int? {
        guard config.chunkLengthS != nil, let overlap = config.overlap, let cl = chunkLength else {
            return nil
        }
        return max(1, Int((1.0 - overlap) * Float(cl)))
    }

    func decodeFrame(_ codes: MLXArray, scale: MLXArray? = nil) -> MLXArray {
        let embeddings = quantizer.decode(codes)
        var outputs = decoder(embeddings)
        if let scale = scale {
            outputs = outputs * scale
        }
        return outputs
    }

    func decode(
        audioCodes: MLXArray,
        audioScales: [MLXArray?],
        paddingMask: MLXArray? = nil
    ) -> MLXArray {
        let cl = chunkLength
        var audioValues: MLXArray

        if cl == nil {
            precondition(audioCodes.dim(1) == 1, "Expected one frame, got \(audioCodes.dim(1))")
            audioValues = decodeFrame(audioCodes[0..., 0, 0..., 0...], scale: audioScales[0])
        } else {
            // chunk-based decoding with linear overlap-add
            var decodedFrames: [MLXArray] = []
            for i in 0 ..< audioCodes.dim(0) {
                let frame = audioCodes[i]
                let scale = audioScales[i]
                let decoded = decodeFrame(frame, scale: scale)
                decodedFrames.append(decoded)
            }
            audioValues = linearOverlapAdd(decodedFrames, stride: chunkStride ?? 1)
        }

        if let paddingMask = paddingMask, paddingMask.dim(1) < audioValues.dim(1) {
            audioValues = audioValues[0..., 0 ..< paddingMask.dim(1)]
        }

        return audioValues
    }

    private func linearOverlapAdd(_ frames: [MLXArray], stride: Int) -> MLXArray {
        precondition(!frames.isEmpty)
        let dtype = frames[0].dtype
        let N = frames[0].dim(0)
        let frameLength = frames[0].dim(1)
        let C = frames[0].dim(2)
        let totalSize = stride * (frames.count - 1) + frames.last!.dim(1)
        
        let timeVec = MLX.linspace(0.0, 1.0, count: frameLength + 2).asType(dtype)[1..<frameLength + 1]
        let weight = 0.5 - abs(timeVec[1 ..< frameLength + 1] - 0.5)
        let weight2d = weight.reshaped(-1, 1)

        var sumWeight = MLXArray.zeros([totalSize, 1]).asType(dtype)
        var out = MLXArray.zeros([N, totalSize, C]).asType(dtype)
        var offset = 0

        for frame in frames {
            let fl = frame.dim(1)
            let w = weight2d[0 ..< fl]
            out[0..., offset ..< offset + fl] = out[0..., offset ..< offset + fl] + w * frame
            sumWeight[offset ..< offset + fl] = sumWeight[offset ..< offset + fl] + w
            offset += stride
        }

        return out / sumWeight
    }

}



// MARK: - Encodec Conv1d (with padding)

class EncodecConv1d: Module {
    let causal: Bool
    let padMode: PadMode
    let normTypeName: String
    let strideVal: Int
    let kernelSizeVal: Int
    let paddingTotal: Int

    @ModuleInfo var conv: Conv1d
    @ModuleInfo var norm: GroupNorm?

    init(config: MusicGenAudioEncoderParameters, inChannels: Int, outChannels: Int, kernelSize: Int, stride: Int = 1, dilation: Int = 1) {
        self.causal = config.useCausalConv
        self.padMode = config.padMode
        self.normTypeName = config.normType
        self.strideVal = stride
        self.kernelSizeVal = (kernelSize - 1) * dilation + 1
        self.paddingTotal = kernelSize - stride

        self._conv.wrappedValue = Conv1d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: kernelSize,
            stride: stride,
            dilation: dilation,
            bias: true
        )

        if config.normType == "time_group_norm" {
            self._norm.wrappedValue = GroupNorm(
                groupCount: 1,
                dimensions: outChannels,
                pytorchCompatible: true
            )
        } else {
            self._norm.wrappedValue = nil
        }
    }

    private func getExtraPaddingForConv1d(_ hiddenStates: MLXArray) -> Int {
        let length = hiddenStates.dim(1)
        let nFrames = Float(length - kernelSizeVal + paddingTotal) / Float(strideVal) + 1
        let nFramesInt = Int(ceil(nFrames)) - 1
        let idealLength = nFramesInt * strideVal + kernelSizeVal - paddingTotal
        return idealLength - length
    }

    private func pad1d(_ hiddenStates: MLXArray, paddings: (Int, Int), mode: PadMode = .zero) -> MLXArray {
        switch mode {
        case .reflect:
            let length = hiddenStates.dim(1)
            let leftPad = paddings.0
            let rightPad = paddings.1
            
            var result = hiddenStates
            if leftPad > 0 {
                let prefix = hiddenStates[0..., 1 ..< (leftPad + 1), 0...]
                let flipped = prefix[0..., stride(from: prefix.dim(1) - 1, to: 0, by: -1), 0...]
                result = concatenated([flipped, result], axis: 1)
            }
            if rightPad > 0 {
                let start = max(length - (rightPad + 1), 0)
                let suffix = hiddenStates[0..., start ..< (length - 1), 0...]
                let flipped = suffix[0..., stride(from: suffix.dim(1) - 1, to: 0, by: -1), 0...]
                result = concatenated([result, flipped], axis: 1)
            }
            return result
        case .zero:
            let leftPad = paddings.0
            let rightPad = paddings.1
            if leftPad == 0 && rightPad == 0 {
                return hiddenStates
            }
            return padded(hiddenStates, widths: [.init((0, 0)), .init((leftPad, rightPad)), .init((0, 0))])
        }
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        let extraPadding = getExtraPaddingForConv1d(hiddenStates)
        var x = hiddenStates

        if causal {
            x = pad1d(x, paddings: (paddingTotal, extraPadding), mode: padMode)
        } else {
            let paddingRight = paddingTotal / 2
            let paddingLeft = paddingTotal - paddingRight
            x = pad1d(x, paddings: (paddingLeft, paddingRight + extraPadding), mode: padMode)
        }

        x = conv(x)

        if let norm = norm {
            x = norm(x)
        }

        return x
    }
}

// MARK: - Encodec ConvTranspose1d

class EncodecConvTranspose1d: Module {
    let causal: Bool
    let trimRightRatio: Float
    let normTypeName: String
    let paddingTotal: Int

    @ModuleInfo var conv: ConvTransposed1d
    @ModuleInfo var norm: GroupNorm?

    init(config: MusicGenAudioEncoderParameters, inChannels: Int, outChannels: Int, kernelSize: Int, stride: Int = 1) {
        self.causal = config.useCausalConv
        self.trimRightRatio = config.trimRightRatio ?? 1.0
        self.normTypeName = config.normType
        self.paddingTotal = kernelSize - stride

        self.conv = ConvTransposed1d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: kernelSize,
            stride: stride,
            bias: true
        )

        if config.normType == "time_group_norm" {
            self.norm = GroupNorm(
                groupCount: 1,
                dimensions: outChannels,
                pytorchCompatible: true
            )
        } else {
            self.norm = nil
        }
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        var x = conv(hiddenStates)

        if let norm = norm {
            x = norm(x)
        }

        let paddingRight: Int
        if causal {
            paddingRight = Int(ceil(Float(paddingTotal) * trimRightRatio))
        } else {
            paddingRight = paddingTotal / 2
        }

        let paddingLeft = paddingTotal - paddingRight
        let end = x.dim(1) - paddingRight
        x = x[0..., paddingLeft ..< end, 0...]
        return x
    }
}

// MARK: - Encodec LSTM

class EncodecLSTM: Module {
    @ModuleInfo var lstm: [LSTM]

    init(config: MusicGenAudioEncoderParameters, dimension: Int) {
        self.lstm = (0 ..< config.numLstmLayers).map { _ in
            LSTM(inputSize: dimension, hiddenSize: dimension)
        }
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        var h = hiddenStates
        for lstm in lstm {
            let (output, _) = lstm(h)
            h = output
        }
        return h + hiddenStates
    }
}

// MARK: - Encodec ResNet Block

class EncodecResnetBlock: Module {
    @ModuleInfo var block: [Module]
    @ModuleInfo var shortcut: Module

    init(config: MusicGenAudioEncoderParameters, dim: Int, dilations: [Int]) {
        let kernelSizes = [config.residualKernelSize, 1]
        precondition(kernelSizes.count == dilations.count)

        let hidden = dim / config.compress
        var blockLayers: [Module] = []
        for (i, (kernelSize, dilation)) in zip(kernelSizes, dilations).enumerated() {
            let inChs = i == 0 ? dim : hidden
            let outChs = i == kernelSizes.count - 1 ? dim : hidden
            blockLayers.append(ELU())
            blockLayers.append(
                EncodecConv1d(
                    config: config, inChannels: inChs, outChannels: outChs,
                    kernelSize: kernelSize, dilation: dilation
                )
            )
        }
        self.block = blockLayers

        let useConvShortcut = config.useConvShortcut ?? true
        if useConvShortcut {
            self.shortcut = EncodecConv1d(
                config: config, inChannels: dim, outChannels: dim, kernelSize: 1
            )
        } else {
            self.shortcut = Identity()
        }
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        let residual = hiddenStates
        var x = hiddenStates
        for layer in block {
            if let eluLayer = layer as? ELU {
                x = eluLayer(x)
            } else if let convLayer = layer as? EncodecConv1d {
                x = convLayer(x)
            }
        }
        if let conv = shortcut as? EncodecConv1d {
            return conv(residual) + x
        } else {
            return residual + x
        }
    }
}

// MARK: - ELU Activation

class ELU: Module, UnaryLayer {
    let alpha: Float

    init(alpha: Float = 1.0) {
        self.alpha = alpha
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        elu(x, alpha: alpha)
    }
}

// MARK: - Encodec Encoder

class EncodecEncoder: Module {
    @ModuleInfo var layers: [Module]

    init(config: MusicGenAudioEncoderParameters) {
        var model: [Module] = []
        model.append(
            EncodecConv1d(
                config: config,
                inChannels: config.audioChannels,
                outChannels: config.numFilters,
                kernelSize: config.kernelSize
            )
        )

        var scaling = 1
        for ratio in config.upsamplingRatios.reversed() {
            let currentScale = scaling * config.numFilters
            for j in 0 ..< config.numResidualLayers {
                let dilation = Int(pow(Double(config.dilationGrowthRate), Double(j)))
                model.append(
                    EncodecResnetBlock(config: config, dim: currentScale, dilations: [dilation, 1])
                )
            }
            model.append(ELU())
            model.append(
                EncodecConv1d(
                    config: config,
                    inChannels: currentScale,
                    outChannels: currentScale * 2,
                    kernelSize: ratio * 2,
                    stride: ratio
                )
            )
            scaling *= 2
        }

        model.append(EncodecLSTM(config: config, dimension: scaling * config.numFilters))
        model.append(ELU())
        model.append(
            EncodecConv1d(
                config: config,
                inChannels: scaling * config.numFilters,
                outChannels: config.hiddenSize,
                kernelSize: config.lastKernelSize
            )
        )

        self.layers = model
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        var x = hiddenStates
        for layer in layers {
            if let conv = layer as? EncodecConv1d {
                x = conv(x)
            } else if let elu = layer as? ELU {
                x = elu(x)
            } else if let resnet = layer as? EncodecResnetBlock {
                x = resnet(x)
            } else if let lstm = layer as? EncodecLSTM {
                x = lstm(x)
            }
        }
        return x
    }
}

// MARK: - Encodec Decoder

class EncodecDecoder: Module {
    @ModuleInfo var layers: [Module]

    init(config: MusicGenAudioEncoderParameters) {
        var scaling = Int(pow(2.0, Double(config.upsamplingRatios.count)))
        var model: [Module] = []

        model.append(
            EncodecConv1d(
                config: config,
                inChannels: config.hiddenSize,
                outChannels: scaling * config.numFilters,
                kernelSize: config.kernelSize
            )
        )

        model.append(EncodecLSTM(config: config, dimension: scaling * config.numFilters))

        for ratio in config.upsamplingRatios {
            let currentScale = scaling * config.numFilters
            model.append(ELU())
            model.append(
                EncodecConvTranspose1d(
                    config: config,
                    inChannels: currentScale,
                    outChannels: currentScale / 2,
                    kernelSize: ratio * 2,
                    stride: ratio
                )
            )
            for j in 0 ..< config.numResidualLayers {
                let dilation = Int(pow(Double(config.dilationGrowthRate), Double(j)))
                model.append(
                    EncodecResnetBlock(
                        config: config, dim: currentScale / 2, dilations: [dilation, 1]
                    )
                )
            }
            scaling /= 2
        }

        model.append(ELU())
        model.append(
            EncodecConv1d(
                config: config,
                inChannels: config.numFilters,
                outChannels: config.audioChannels,
                kernelSize: config.lastKernelSize
            )
        )

        self.layers = model
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        var x = hiddenStates
        for layer in layers {
            if let conv = layer as? EncodecConv1d {
                x = conv(x)
            } else if let convT = layer as? EncodecConvTranspose1d {
                x = convT(x)
            } else if let elu = layer as? ELU {
                x = elu(x)
            } else if let resnet = layer as? EncodecResnetBlock {
                x = resnet(x)
            } else if let lstm = layer as? EncodecLSTM {
                x = lstm(x)
            }
        }
        return x
    }
}

// MARK: - Euclidean Codebook

class EncodecEuclideanCodebook: Module {
    @ModuleInfo var embed: MLXArray

    init(config: MusicGenAudioEncoderParameters) {
        self.embed = MLXArray.zeros([config.codebookSize, config.codebookDim])
    }

    func quantize(_ hiddenStates: MLXArray) -> MLXArray {
        let embedT = embed.T
        let scaledStates = hiddenStates.square().sum(axis: 1, keepDims: true)
        let dist = -(scaledStates - 2 * matmul(hiddenStates, embedT) + embedT.square().sum(axis: 0, keepDims: true))
        return argMax(dist, axis: -1)
    }

    func encode(_ hiddenStates: MLXArray) -> MLXArray {
        let shape = hiddenStates.shape
        let flat = hiddenStates.reshaped(-1, shape.last!)
        var embedInd = quantize(flat)
        embedInd = embedInd.reshaped(Array(shape.dropLast()))
        return embedInd
    }

    func decode(_ embedInd: MLXArray) -> MLXArray {
        return embed[embedInd]
    }
}

// MARK: - Vector Quantization

class EncodecVectorQuantization: Module {
    @ModuleInfo var codebook: EncodecEuclideanCodebook

    init(config: MusicGenAudioEncoderParameters) {
        self.codebook = EncodecEuclideanCodebook(config: config)
    }

    func encode(_ hiddenStates: MLXArray) -> MLXArray {
        codebook.encode(hiddenStates)
    }

    func decode(_ embedInd: MLXArray) -> MLXArray {
        codebook.decode(embedInd)
    }
}

// MARK: - Residual Vector Quantizer

class EncodecResidualVectorQuantizer: Module {
    let codebookSize: Int
    let frameRate: Int
    let numQuantizers: Int
    @ModuleInfo var layers: [EncodecVectorQuantization]

    init(config: MusicGenAudioEncoderParameters) {
        self.codebookSize = config.codebookSize
        let hopLength = config.upsamplingRatios.reduce(1, *)
        self.frameRate = Int(ceil(Double(config.samplingRate) / Double(hopLength)))
        self.numQuantizers = Int(1000 * config.targetBandwidths.last! / Float(frameRate * 10))
        self.layers = (0 ..< numQuantizers).map { _ in
            EncodecVectorQuantization(config: config)
        }
    }

    func getNumQuantizersForBandwidth(_ bandwidth: Float? = nil) -> Int {
        let bwPerQ = log2(Float(codebookSize)) * Float(frameRate)
        var nq = numQuantizers
        if let bandwidth = bandwidth, bandwidth > 0 {
            nq = Int(max(1, floor(bandwidth * 1000 / bwPerQ)))
        }
        return nq
    }

    func encode(_ embeddings: MLXArray, bandwidth: Float? = nil) -> MLXArray {
        let nq = getNumQuantizersForBandwidth(bandwidth)
        var residual = embeddings
        var allIndices: [MLXArray] = []

        for i in 0 ..< nq {
            let indices = layers[i].encode(residual)
            let quantized = layers[i].decode(indices)
            residual = residual - quantized
            allIndices.append(indices)
        }
        return stacked(allIndices, axis: 1)
    }

    func decode(_ codes: MLXArray) -> MLXArray {
        var quantizedOut: MLXArray? = nil
        for i in 0 ..< codes.dim(1) {
            let indices = codes[0..., i, 0...]
            let quantized = layers[i].decode(indices)
            if let qo = quantizedOut {
                quantizedOut = qo + quantized
            } else {
                quantizedOut = quantized
            }
        }
        return quantizedOut!
    }
}
