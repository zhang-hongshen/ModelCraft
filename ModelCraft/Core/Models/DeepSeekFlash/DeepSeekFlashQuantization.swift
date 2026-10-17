//
//  DeepSeekFlashQuantization.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//
import Foundation
import MLX
import MLXNN

enum DeepSeekFlashLinearStorage {
    case bfloat16
    case mxfp8Block128
    case mxfp4Group32
}

final class DeepSeekFlashLinear: Module {
    let inputDimensions: Int
    let outputDimensions: Int
    let storage: DeepSeekFlashLinearStorage

    @ParameterInfo(key: "weight") var weight: MLXArray
    @ParameterInfo(key: "scale") var scale: MLXArray?

    init(_ inputDimensions: Int, _ outputDimensions: Int, storage: DeepSeekFlashLinearStorage) {
        self.inputDimensions = inputDimensions
        self.outputDimensions = outputDimensions
        self.storage = storage

        switch storage {
        case .bfloat16:
            _weight.wrappedValue = MLXArray.zeros(
                [outputDimensions, inputDimensions], dtype: .bfloat16)
            _scale.wrappedValue = nil
        case .mxfp8Block128:
            _weight.wrappedValue = MLXArray.zeros(
                [outputDimensions, inputDimensions / 4], dtype: .uint32)
            _scale.wrappedValue = MLXArray.zeros(
                [(outputDimensions + 127) / 128, (inputDimensions + 127) / 128],
                dtype: .uint8)
        case .mxfp4Group32:
            _weight.wrappedValue = MLXArray.zeros(
                [outputDimensions, inputDimensions / 8], dtype: .uint32)
            _scale.wrappedValue = MLXArray.zeros(
                [outputDimensions, inputDimensions / 32], dtype: .uint8)
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        switch storage {
        case .bfloat16:
            return x.matmul(weight.swappedAxes(-1, -2))
        case .mxfp8Block128:
            return quantizedMM(
                x, weight,
                scales: expandedFP8Scales(), biases: nil,
                transpose: true, groupSize: 32, bits: 8, mode: .mxfp8)
        case .mxfp4Group32:
            return quantizedMM(
                x, weight,
                scales: scale!, biases: nil,
                transpose: true, groupSize: 32, bits: 4, mode: .mxfp4)
        }
    }

    func dequantizedWeight(dtype: DType = .bfloat16) -> MLXArray {
        switch storage {
        case .bfloat16:
            return weight.asType(dtype)
        case .mxfp8Block128:
            return dequantized(
                weight, scales: expandedFP8Scales(), biases: nil,
                groupSize: 32, bits: 8, mode: .mxfp8, dtype: dtype)
        case .mxfp4Group32:
            return dequantized(
                weight, scales: scale!, biases: nil,
                groupSize: 32, bits: 4, mode: .mxfp4, dtype: dtype)
        }
    }

    private func expandedFP8Scales() -> MLXArray {
        let rows = MLX.repeated(scale!, count: 128, axis: 0)[0 ..< outputDimensions]
        let groups = MLX.repeated(rows, count: 4, axis: 1)
        return groups[0..., 0 ..< (inputDimensions / 32)]
    }
}

final class DeepSeekFlashRMSNorm: Module {
    let epsilon: Float
    @ParameterInfo(key: "weight") var weight: MLXArray

    init(dimensions: Int, epsilon: Float) {
        self.epsilon = epsilon
        _weight.wrappedValue = MLXArray.ones([dimensions], dtype: .float32)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x.asType(.float32), weight: weight, eps: epsilon).asType(x.dtype)
    }
}

enum DeepSeekFlashRoPE {
    static func apply(
        _ x: MLXArray,
        start: Int,
        step: Int = 1,
        dimension: Int,
        base: Float,
        originalSequenceLength: Int,
        factor: Float,
        betaFast: Int,
        betaSlow: Int,
        inverse: Bool = false
    ) -> MLXArray {
        let half = dimension / 2
        let logBase = Float(Foundation.log(Double(base)))
        let frequencyScale = 2.0 / Float(dimension)
        let frequencyIndices: MLXArray = MLX.arange(half, dtype: .float32)
        let scaledFrequencies: MLXArray = frequencyIndices * frequencyScale
        var frequencies: MLXArray = MLX.exp(scaledFrequencies * -logBase)

        if originalSequenceLength > 0 {
            let fastCorrection = correctionDimension(
                rotations: Float(betaFast), dimension: dimension,
                base: base, sequenceLength: originalSequenceLength)
            let slowCorrection = correctionDimension(
                rotations: Float(betaSlow), dimension: dimension,
                base: base, sequenceLength: originalSequenceLength)
            let low = max(
                0, Int(Foundation.floor(Double(fastCorrection))))
            let high = min(
                dimension - 1, Int(Foundation.ceil(Double(slowCorrection)))
            )
            let denominator = Float(low == high ? Int(0.001) : high - low)
            let rampIndices: MLXArray = MLX.arange(half, dtype: .float32)
            let shiftedRampIndices: MLXArray = rampIndices - Float(low)
            let rampValues: MLXArray = shiftedRampIndices / denominator
            let ramp: MLXArray = MLX.clip(rampValues, min: 0, max: 1)
            let smooth: MLXArray = 1 - ramp
            let scaledFrequencies: MLXArray = frequencies / factor
            let lowFrequencyWeight: MLXArray = 1 - smooth
            let lowFrequencyPart: MLXArray = scaledFrequencies * lowFrequencyWeight
            let highFrequencyPart: MLXArray = frequencies * smooth
            frequencies = lowFrequencyPart + highFrequencyPart
        }

        // The fused kernel rotates the leading channels of axis -1 at positions
        // `scale * (offset + i)` along axis -2; this layout rotates the trailing
        // channels at `start + i * step` along axis 1.
        precondition(start % step == 0)
        let rotary = x[.ellipsis, (x.dim(-1) - dimension)...]
        let rotated = MLXFast.RoPE(
            rotary.swappedAxes(1, -2),
            dimensions: dimension,
            traditional: true,
            base: nil,
            scale: Float(inverse ? -step : step),
            offset: start / step,
            freqs: 1 / frequencies)
            .swappedAxes(1, -2)
        return MLX.concatenated([x[.ellipsis, 0 ..< (x.dim(-1) - dimension)], rotated], axis: -1)
    }

    private static func correctionDimension(
        rotations: Float,
        dimension: Int,
        base: Float,
        sequenceLength: Int
    ) -> Float {
        let rotationPeriod = Double(rotations) * 2 * Double.pi
        let scaledSequenceLength = Double(sequenceLength) / rotationPeriod
        let sequenceLog = Float(Foundation.log(scaledSequenceLength))
        let baseLog = Float(Foundation.log(Double(base)))
        let denominator = 2 * baseLog
        return Float(dimension) * sequenceLog / denominator
    }
}
