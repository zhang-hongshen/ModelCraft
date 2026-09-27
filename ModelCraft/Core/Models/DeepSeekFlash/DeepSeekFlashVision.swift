//
//  DeepSeekFlashVision.swift
//  ModelCraft
//
//  Created by Hongshen on 27/9/26.
//

import Foundation
import MLX
import MLXNN

final class DeepSeekFlashDense: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    @ParameterInfo(key: "bias") var bias: MLXArray?

    init(inputDimensions: Int, outputDimensions: Int, bias: Bool) {
        _weight.wrappedValue = MLXArray.zeros(
            [outputDimensions, inputDimensions], dtype: .bfloat16)
        _bias.wrappedValue = bias
            ? MLXArray.zeros([outputDimensions], dtype: .bfloat16)
            : nil
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let output = x.matmul(weight.swappedAxes(-1, -2))
        return bias.map { output + $0 } ?? output
    }
}

final class DeepSeekFlashVisionPatchEmbedding: Module {
    @ModuleInfo(key: "proj") var projection: DeepSeekFlashDense

    init(configuration: DeepSeekFlashConfiguration) {
        _projection.wrappedValue = DeepSeekFlashDense(
            inputDimensions: 3 * configuration.visionPatchSize * configuration.visionPatchSize,
            outputDimensions: configuration.visionDimension,
            bias: true)
        super.init()
    }

    func callAsFunction(_ patches: MLXArray) -> MLXArray {
        projection(patches.flattened(start: 1))
    }
}

final class DeepSeekFlashVisionAttention: Module {
    let headCount: Int
    let headDimension: Int
    @ModuleInfo(key: "wqkv") var queryKeyValue: DeepSeekFlashDense
    @ModuleInfo(key: "wo") var output: DeepSeekFlashDense

    init(configuration: DeepSeekFlashConfiguration) {
        headCount = configuration.visionHeadCount
        headDimension = configuration.visionDimension / configuration.visionHeadCount
        _queryKeyValue.wrappedValue = DeepSeekFlashDense(
            inputDimensions: configuration.visionDimension,
            outputDimensions: 3 * configuration.visionDimension,
            bias: true)
        _output.wrappedValue = DeepSeekFlashDense(
            inputDimensions: configuration.visionDimension,
            outputDimensions: configuration.visionDimension,
            bias: true)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cosine: MLXArray, sine: MLXArray) -> MLXArray {
        let count = x.dim(0)
        let parts = queryKeyValue(x)
            .reshaped([count, 3, headCount, headDimension])
            .transposed(1, 0, 2, 3)
        let query = Self.applyRotary(parts[0], cosine: cosine, sine: sine)
        let key = Self.applyRotary(parts[1], cosine: cosine, sine: sine)
        let value = parts[2]
        let attended = MLXFast.scaledDotProductAttention(
            queries: query.transposed(1, 0, 2).expandedDimensions(axis: 0),
            keys: key.transposed(1, 0, 2).expandedDimensions(axis: 0),
            values: value.transposed(1, 0, 2).expandedDimensions(axis: 0),
            scale: 1 / Float(headDimension).squareRoot(),
            mask: nil)
        return output(
            attended.squeezed(axis: 0)
                .transposed(1, 0, 2)
                .reshaped([count, headCount * headDimension]))
    }

    private static func applyRotary(
        _ x: MLXArray,
        cosine: MLXArray,
        sine: MLXArray
    ) -> MLXArray {
        let half = x.dim(-1) / 2
        let first = x[.ellipsis, 0 ..< half].asType(.float32)
        let second = x[.ellipsis, half...].asType(.float32)
        return MLX.concatenated(
            [first * cosine - second * sine, second * cosine + first * sine],
            axis: -1)
            .asType(x.dtype)
    }
}

final class DeepSeekFlashVisionMLP: Module {
    let intermediateSize: Int
    @ModuleInfo(key: "w1") var input: DeepSeekFlashDense
    @ModuleInfo(key: "w2") var output: DeepSeekFlashDense

    init(configuration: DeepSeekFlashConfiguration) {
        intermediateSize = configuration.visionIntermediateSize
        _input.wrappedValue = DeepSeekFlashDense(
            inputDimensions: configuration.visionDimension,
            outputDimensions: 2 * configuration.visionIntermediateSize,
            bias: false)
        _output.wrappedValue = DeepSeekFlashDense(
            inputDimensions: configuration.visionIntermediateSize,
            outputDimensions: configuration.visionDimension,
            bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let projected = input(x)
        return output(
            MLXNN.silu(projected[.ellipsis, 0 ..< intermediateSize])
                * projected[.ellipsis, intermediateSize...])
    }
}

final class DeepSeekFlashVisionBlock: Module {

    @ModuleInfo(key: "attn") var attention: DeepSeekFlashVisionAttention
    @ModuleInfo(key: "mlp") var feedForward: DeepSeekFlashVisionMLP
    @ModuleInfo(key: "norm1") var attentionNorm: DeepSeekFlashRMSNorm
    @ModuleInfo(key: "norm2") var feedForwardNorm: DeepSeekFlashRMSNorm

    init(configuration: DeepSeekFlashConfiguration) {
        _attentionNorm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.visionDimension, epsilon: 1e-6)
        _attention.wrappedValue = DeepSeekFlashVisionAttention(configuration: configuration)
        _feedForwardNorm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.visionDimension, epsilon: 1e-6)
        _feedForward.wrappedValue = DeepSeekFlashVisionMLP(configuration: configuration)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cosine: MLXArray, sine: MLXArray) -> MLXArray {
        let attended = x + attention(attentionNorm(x), cosine: cosine, sine: sine)
        return attended + feedForward(feedForwardNorm(attended))
    }
}

final class DeepSeekFlashVisionEncoder: Module {
    let configuration: DeepSeekFlashConfiguration
    @ModuleInfo(key: "patch_embed") var patchEmbedding: DeepSeekFlashVisionPatchEmbedding
    @ModuleInfo(key: "blocks") var blocks: [DeepSeekFlashVisionBlock]
    @ModuleInfo(key: "norm") var norm: DeepSeekFlashRMSNorm

    init(configuration: DeepSeekFlashConfiguration) {
        self.configuration = configuration
        _patchEmbedding.wrappedValue = DeepSeekFlashVisionPatchEmbedding(
            configuration: configuration)
        _blocks.wrappedValue = (0 ..< configuration.visionLayerCount).map { _ in
            DeepSeekFlashVisionBlock(configuration: configuration)
        }
        _norm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.visionDimension, epsilon: 1e-6)
        super.init()
    }

    func callAsFunction(
        _ patches: MLXArray,
        height: Int,
        width: Int
    ) -> MLXArray {
        var hidden = patchEmbedding(patches)
        let rotary = rotaryEmbeddings(height: height, width: width)
        for block in blocks {
            hidden = block(hidden, cosine: rotary.cosine, sine: rotary.sine)
        }
        return norm(hidden)
    }

    private func rotaryEmbeddings(
        height: Int,
        width: Int
    ) -> (cosine: MLXArray, sine: MLXArray) {
        let ropeDimension = configuration.visionDimension
            / configuration.visionHeadCount / 2
        let frequencies = MLX.exp(
            -log(configuration.visionRopeTheta)
                * MLX.arange(0, ropeDimension, step: 2, dtype: .float32)
                / Float(ropeDimension))
        var heightPositions = [Float]()
        var widthPositions = [Float]()
        heightPositions.reserveCapacity(height * width)
        widthPositions.reserveCapacity(height * width)
        for row in 0 ..< height {
            for column in 0 ..< width {
                heightPositions.append(Float(row))
                widthPositions.append(Float(column))
            }
        }
        let heightAngles = MLXArray(heightPositions).expandedDimensions(axis: 1)
            * frequencies.expandedDimensions(axis: 0)
        let widthAngles = MLXArray(widthPositions).expandedDimensions(axis: 1)
            * frequencies.expandedDimensions(axis: 0)
        let angles = MLX.concatenated([heightAngles, widthAngles], axis: -1)
            .expandedDimensions(axis: 1)
        return (MLX.cos(angles), MLX.sin(angles))
    }
}

final class DeepSeekFlashVisionAligner: Module {
    let downsampleRatio: Int
    @ModuleInfo(key: "w1") var input: DeepSeekFlashDense
    @ModuleInfo(key: "w2") var output: DeepSeekFlashDense

    init(configuration: DeepSeekFlashConfiguration) {
        downsampleRatio = configuration.visionDownsampleRatio
        _input.wrappedValue = DeepSeekFlashDense(
            inputDimensions: configuration.visionDimension
                * configuration.visionDownsampleRatio * configuration.visionDownsampleRatio,
            outputDimensions: configuration.hiddenSize,
            bias: true)
        _output.wrappedValue = DeepSeekFlashDense(
            inputDimensions: configuration.hiddenSize,
            outputDimensions: configuration.hiddenSize,
            bias: true)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, height: Int, width: Int) -> MLXArray {
        let ratio = downsampleRatio
        let paddedHeight = (height + ratio - 1) / ratio * ratio
        let paddedWidth = (width + ratio - 1) / ratio * ratio
        var value = x.reshaped([height, width, x.dim(-1)]).transposed(2, 0, 1)
        let dimensions = value.dim(0)
        value = MLX.padded(
            value,
            widths: [
                .init(arrayLiteral: 0, 0),
                .init(arrayLiteral: 0, paddedHeight - height),
                .init(arrayLiteral: 0, paddedWidth - width),
            ])
        value = value
            .reshaped([
                value.dim(0), paddedHeight / ratio, ratio,
                paddedWidth / ratio, ratio,
            ])
            .transposed(1, 3, 0, 2, 4)
            .flattened(start: 2)
            .reshaped([-1, dimensions * ratio * ratio])
        return output(MLXNN.gelu(input(value)))
    }
}
