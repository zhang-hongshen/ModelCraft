//
//  DeepSeekFlashAttention.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import MLX
import MLXNN

struct DeepSeekFlashImageVisibility {
    let left: [Int]
    let right: [Int]
}

class DeepSeekFlashAttention: Module {
    let configuration: DeepSeekFlashConfiguration
    let layerID: Int
    let compressionRatio: Int
    let softmaxScale: Float

    @ParameterInfo(key: "attn_sink") var attentionSink: MLXArray
    @ModuleInfo(key: "compressor") var compressor: DeepSeekFlashCompressor?
    @ModuleInfo(key: "indexer") var indexer: DeepSeekFlashIndexer?
    @ModuleInfo(key: "kv_norm") var keyValueNorm: DeepSeekFlashRMSNorm
    @ModuleInfo(key: "q_norm") var queryNorm: DeepSeekFlashRMSNorm
    @ModuleInfo(key: "wkv") var keyValue: DeepSeekFlashLinear
    @ModuleInfo(key: "wo_a") var outputA: DeepSeekFlashLinear
    @ModuleInfo(key: "wo_b") var outputB: DeepSeekFlashLinear
    @ModuleInfo(key: "wq_a") var queryA: DeepSeekFlashLinear
    @ModuleInfo(key: "wq_b") var queryB: DeepSeekFlashLinear

    init(layerID: Int, configuration: DeepSeekFlashConfiguration) {
        self.layerID = layerID
        self.configuration = configuration
        compressionRatio = configuration.compressRatios[layerID]
        softmaxScale = 1 / Float(configuration.headDimension).squareRoot()
        _attentionSink.wrappedValue = MLXArray.zeros(
            [configuration.numAttentionHeads], dtype: .float32)
        _queryA.wrappedValue = DeepSeekFlashLinear(
            configuration.hiddenSize, configuration.qLoraRank, storage: .mxfp8Block128)
        _queryNorm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.qLoraRank, epsilon: configuration.rmsNormEpsilon)
        _queryB.wrappedValue = DeepSeekFlashLinear(
            configuration.qLoraRank,
            configuration.numAttentionHeads * configuration.headDimension,
            storage: .mxfp8Block128)
        _keyValue.wrappedValue = DeepSeekFlashLinear(
            configuration.hiddenSize, configuration.headDimension, storage: .mxfp8Block128)
        _keyValueNorm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.headDimension, epsilon: configuration.rmsNormEpsilon)
        _outputA.wrappedValue = DeepSeekFlashLinear(
            configuration.numAttentionHeads * configuration.headDimension
                / configuration.outputGroups,
            configuration.outputGroups * configuration.outputLoraRank,
            storage: .mxfp8Block128)
        _outputB.wrappedValue = DeepSeekFlashLinear(
            configuration.outputGroups * configuration.outputLoraRank,
            configuration.hiddenSize,
            storage: .mxfp8Block128)
        if compressionRatio > 0 {
            _compressor.wrappedValue = DeepSeekFlashCompressor(
                configuration: configuration,
                ratio: compressionRatio,
                headDimension: configuration.headDimension)
            _indexer.wrappedValue = compressionRatio == 4
                ? DeepSeekFlashIndexer(configuration: configuration, ratio: compressionRatio)
                : nil
        } else {
            _compressor.wrappedValue = nil
            _indexer.wrappedValue = nil
        }
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        startPosition: Int,
        state: DeepSeekFlashAttentionState,
        imageVisibility: DeepSeekFlashImageVisibility? = nil
    ) -> MLXArray {
        let batchSize = x.dim(0)
        let sequenceLength = x.dim(1)
        let endPosition = startPosition + sequenceLength
        let window = configuration.slidingWindow

        let reducedQuery = queryNorm(queryA(x))
        var query = queryB(reducedQuery).reshaped([
            batchSize, sequenceLength,
            configuration.numAttentionHeads,
            configuration.headDimension,
        ])
        query = query * rsqrt(mean(query * query, axis: -1, keepDims: true)
            + configuration.rmsNormEpsilon)
        query = applyRoPE(query, positions: Array(startPosition ..< endPosition))

        var currentKeyValue = applyRoPE(
            keyValueNorm(keyValue(x)), positions: Array(startPosition ..< endPosition))
        var indices = windowIndices(
            batchSize: batchSize,
            sequenceLength: sequenceLength,
            startPosition: startPosition,
            window: window,
            imageVisibility: imageVisibility,
            maximumImageTokens: configuration.visionMaximumTokenCount)

        if compressionRatio > 0 {
            let offset = startPosition == 0 ? sequenceLength : window
            let compressedIndices: MLXArray
            if let indexer {
                compressedIndices = indexer(
                    x,
                    reducedQuery: reducedQuery,
                    startPosition: startPosition,
                    offset: offset,
                    state: state)
            } else {
                compressedIndices = compressionIndices(
                    batchSize: batchSize,
                    sequenceLength: sequenceLength,
                    startPosition: startPosition,
                    ratio: compressionRatio,
                    offset: offset)
            }
            indices = MLX.concatenated([indices, compressedIndices], axis: -1)
        }

        let attentionKeyValue: MLXArray
        if startPosition == 0 {
            storePrefillWindow(currentKeyValue, in: state, window: window)
            if let compressor,
               let compressorState = state.compressor,
               let compressed = compressor(
                   x, startPosition: startPosition, state: compressorState)
            {
                state.keyValueCache[
                    0 ..< batchSize,
                    window ..< (window + compressed.dim(1))] = compressed
                currentKeyValue = MLX.concatenated([currentKeyValue, compressed], axis: 1)
            }
            attentionKeyValue = currentKeyValue
        } else {
            state.keyValueCache[0 ..< batchSize, startPosition % window] = currentKeyValue[0..., 0]
            if let compressor, let compressorState = state.compressor,
               let compressed = compressor(
                   x, startPosition: startPosition, state: compressorState)
            {
                state.keyValueCache[
                    0 ..< batchSize, window + startPosition / compressionRatio] = compressed[0..., 0]
            }
            attentionKeyValue = state.keyValueCache[0 ..< batchSize]
        }

        var output = sparseAttention(
            query: query,
            keyValue: attentionKeyValue,
            indices: indices,
            attentionSink: attentionSink,
            scale: softmaxScale)
        output = applyRoPE(
            output, positions: Array(startPosition ..< endPosition), inverse: true)
        return projectOutput(output)
    }

    func projectOutput(_ output: MLXArray) -> MLXArray {
        var output = output.reshaped([
            output.dim(0),
            output.dim(1),
            configuration.outputGroups,
            configuration.numAttentionHeads * configuration.headDimension
                / configuration.outputGroups,
        ])
        let outputAWeight = outputA.dequantizedWeight().reshaped([
            configuration.outputGroups,
            configuration.outputLoraRank,
            configuration.numAttentionHeads * configuration.headDimension
                / configuration.outputGroups,
        ])
        output = MLX.einsum("bsgd,grd->bsgr", output, outputAWeight)
        return outputB(output.flattened(start: 2))
    }

    func applyRoPE(
        _ x: MLXArray,
        positions: [Int],
        inverse: Bool = false
    ) -> MLXArray {
        DeepSeekFlashRoPE.apply(
            x,
            positions: positions,
            dimension: configuration.ropeHeadDimension,
            base: compressionRatio > 0 ? configuration.compressRopeTheta : configuration.ropeTheta,
            originalSequenceLength: compressionRatio > 0
                ? configuration.originalMaxPositionEmbeddings : 0,
            factor: configuration.ropeFactor,
            betaFast: configuration.ropeBetaFast,
            betaSlow: configuration.ropeBetaSlow,
            inverse: inverse)
    }

    private func storePrefillWindow(
        _ value: MLXArray,
        in state: DeepSeekFlashAttentionState,
        window: Int
    ) {
        let batchSize = value.dim(0)
        let sequenceLength = value.dim(1)
        if sequenceLength <= window {
            state.keyValueCache[0 ..< batchSize, 0 ..< sequenceLength] = value
        } else {
            let cutoff = sequenceLength % window
            let tail = value[0..., (sequenceLength - window)...]
            state.keyValueCache[0 ..< batchSize, cutoff ..< window] =
                tail[0..., 0 ..< (window - cutoff)]
            if cutoff > 0 {
                state.keyValueCache[0 ..< batchSize, 0 ..< cutoff] = tail[0..., (window - cutoff)...]
            }
        }
    }
}


final class DeepSeekFlashCompressorState {
    var keyValue: MLXArray
    var score: MLXArray

    init(batchSize: Int, ratio: Int, headDimension: Int, overlapping: Bool) {
        let coefficient = overlapping ? 2 : 1
        keyValue = MLXArray.zeros(
            [batchSize, coefficient * ratio, coefficient * headDimension], dtype: .float32)
        score = MLXArray.full(
            [batchSize, coefficient * ratio, coefficient * headDimension],
            values: MLXArray(-Float.infinity), dtype: .float32)
    }
}

final class DeepSeekFlashAttentionState {
    var keyValueCache: MLXArray
    var indexKeyValueCache: MLXArray?
    let compressor: DeepSeekFlashCompressorState?
    let indexCompressor: DeepSeekFlashCompressorState?

    init(
        configuration: DeepSeekFlashConfiguration,
        layerID: Int,
        batchSize: Int,
        maximumSequenceLength: Int
    ) {
        let ratio = configuration.compressRatios[layerID]
        let compressedCount = ratio == 0 ? 0 : (maximumSequenceLength + ratio - 1) / ratio
        keyValueCache = MLXArray.zeros(
            [
                batchSize,
                configuration.slidingWindow + compressedCount,
                configuration.headDimension,
            ],
            dtype: .bfloat16)
        if ratio > 0 {
            compressor = DeepSeekFlashCompressorState(
                batchSize: batchSize,
                ratio: ratio,
                headDimension: configuration.headDimension,
                overlapping: ratio == 4)
        } else {
            compressor = nil
        }
        if ratio == 4 {
            indexKeyValueCache = MLXArray.zeros(
                [batchSize, compressedCount, configuration.indexHeadDimension],
                dtype: .bfloat16)
            indexCompressor = DeepSeekFlashCompressorState(
                batchSize: batchSize,
                ratio: ratio,
                headDimension: configuration.indexHeadDimension,
                overlapping: true)
        } else {
            indexKeyValueCache = nil
            indexCompressor = nil
        }
    }
}

final class DeepSeekFlashCompressor: Module {
    let ratio: Int
    let headDimension: Int
    let ropeHeadDimension: Int
    let overlapping: Bool
    let rotate: Bool
    let configuration: DeepSeekFlashConfiguration

    @ParameterInfo(key: "ape") var absolutePositionEmbedding: MLXArray
    @ModuleInfo(key: "wkv") var keyValueProjection: DeepSeekFlashLinear
    @ModuleInfo(key: "wgate") var gateProjection: DeepSeekFlashLinear
    @ModuleInfo(key: "norm") var norm: DeepSeekFlashRMSNorm

    init(
        configuration: DeepSeekFlashConfiguration,
        ratio: Int,
        headDimension: Int,
        rotate: Bool = false
    ) {
        self.configuration = configuration
        self.ratio = ratio
        self.headDimension = headDimension
        ropeHeadDimension = configuration.ropeHeadDimension
        overlapping = ratio == 4
        self.rotate = rotate
        let coefficient = overlapping ? 2 : 1
        _absolutePositionEmbedding.wrappedValue = MLXArray.zeros(
            [ratio, coefficient * headDimension], dtype: .float32)
        _keyValueProjection.wrappedValue = DeepSeekFlashLinear(
            configuration.hiddenSize, coefficient * headDimension, storage: .bfloat16)
        _gateProjection.wrappedValue = DeepSeekFlashLinear(
            configuration.hiddenSize, coefficient * headDimension, storage: .bfloat16)
        _norm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: headDimension, epsilon: configuration.rmsNormEpsilon)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        startPosition: Int,
        state: DeepSeekFlashCompressorState
    ) -> MLXArray? {
        let batchSize = x.dim(0)
        let sequenceLength = x.dim(1)
        let coefficient = overlapping ? 2 : 1
        let value = x.asType(.float32)
        var keyValue = keyValueProjection(value).asType(.float32)
        var scores = gateProjection(value).asType(.float32)
        var shouldCompress: Bool
        var compressionPosition: Int

        if startPosition == 0 {
            shouldCompress = sequenceLength >= ratio
            let remainder = sequenceLength % ratio
            let cutoff = sequenceLength - remainder
            let offset = overlapping ? ratio : 0
            compressionPosition = 0

            if overlapping && cutoff >= ratio {
                state.keyValue[0 ..< batchSize, 0 ..< ratio] =
                    keyValue[0..., (cutoff - ratio) ..< cutoff]
                state.score[0 ..< batchSize, 0 ..< ratio] =
                    scores[0..., (cutoff - ratio) ..< cutoff] + absolutePositionEmbedding
            }
            if remainder > 0 {
                state.keyValue[0 ..< batchSize, offset ..< (offset + remainder)] =
                    keyValue[0..., cutoff...]
                state.score[0 ..< batchSize, offset ..< (offset + remainder)] =
                    scores[0..., cutoff...]
                    + absolutePositionEmbedding[0 ..< remainder]
            }
            guard shouldCompress else { return nil }
            keyValue = keyValue[0..., 0 ..< cutoff]
                .reshaped([batchSize, cutoff / ratio, ratio, coefficient * headDimension])
            scores = scores[0..., 0 ..< cutoff]
                .reshaped([batchSize, cutoff / ratio, ratio, coefficient * headDimension])
                + absolutePositionEmbedding

            if overlapping {
                let groupCount = cutoff / ratio
                let emptyKeyValue = MLXArray.zeros(
                    [batchSize, 1, ratio, headDimension], dtype: .float32)
                let emptyScore = MLXArray.full(
                    [batchSize, 1, ratio, headDimension],
                    values: MLXArray(-Float.infinity), dtype: .float32)
                let previousKeyValue = groupCount > 1
                    ? keyValue[0..., 0 ..< (groupCount - 1), 0..., 0 ..< headDimension]
                    : MLXArray.zeros([batchSize, 0, ratio, headDimension], dtype: .float32)
                let previousScore = groupCount > 1
                    ? scores[0..., 0 ..< (groupCount - 1), 0..., 0 ..< headDimension]
                    : MLXArray.zeros([batchSize, 0, ratio, headDimension], dtype: .float32)
                let overlapKeyValue = MLX.concatenated(
                    [emptyKeyValue, previousKeyValue], axis: 1)
                let overlapScore = MLX.concatenated([emptyScore, previousScore], axis: 1)
                keyValue = MLX.concatenated(
                    [overlapKeyValue, keyValue[.ellipsis, headDimension...]], axis: 2)
                scores = MLX.concatenated(
                    [overlapScore, scores[.ellipsis, headDimension...]], axis: 2)
            }
            keyValue = sum(keyValue * softmax(scores, axis: 2), axis: 2)
        } else {
            shouldCompress = (startPosition + 1) % ratio == 0
            compressionPosition = startPosition + 1 - ratio
            scores = scores + absolutePositionEmbedding[startPosition % ratio]
            if overlapping {
                let index = ratio + startPosition % ratio
                state.keyValue[0 ..< batchSize, index] = keyValue[0..., 0]
                state.score[0 ..< batchSize, index] = scores[0..., 0]
                guard shouldCompress else { return nil }
                let overlappingValues = state.keyValue[
                    0 ..< batchSize, 0 ..< ratio, 0 ..< headDimension]
                let currentValues = state.keyValue[
                    0 ..< batchSize, ratio ..< (2 * ratio), headDimension...]
                let overlappingScores = state.score[
                    0 ..< batchSize, 0 ..< ratio, 0 ..< headDimension]
                let currentScores = state.score[
                    0 ..< batchSize, ratio ..< (2 * ratio), headDimension...]
                let values = MLX.concatenated([overlappingValues, currentValues], axis: 1)
                let weights = softmax(
                    MLX.concatenated([overlappingScores, currentScores], axis: 1), axis: 1)
                keyValue = sum(values * weights, axis: 1, keepDims: true)
                state.keyValue[0 ..< batchSize, 0 ..< ratio] =
                    state.keyValue[0 ..< batchSize, ratio ..< (2 * ratio)]
                state.score[0 ..< batchSize, 0 ..< ratio] =
                    state.score[0 ..< batchSize, ratio ..< (2 * ratio)]
            } else {
                let index = startPosition % ratio
                state.keyValue[0 ..< batchSize, index] = keyValue[0..., 0]
                state.score[0 ..< batchSize, index] = scores[0..., 0]
                guard shouldCompress else { return nil }
                keyValue = sum(
                    state.keyValue[0 ..< batchSize]
                        * softmax(state.score[0 ..< batchSize], axis: 1),
                    axis: 1,
                    keepDims: true)
            }
        }

        let positionCount = keyValue.dim(1)
        let positions = Array(stride(
            from: compressionPosition,
            to: compressionPosition + positionCount * ratio,
            by: ratio))
        var output = norm(keyValue.asType(x.dtype))
        output = DeepSeekFlashRoPE.apply(
            output,
            positions: positions,
            dimension: ropeHeadDimension,
            base: configuration.compressRopeTheta,
            originalSequenceLength: configuration.originalMaxPositionEmbeddings,
            factor: configuration.ropeFactor,
            betaFast: configuration.ropeBetaFast,
            betaSlow: configuration.ropeBetaSlow)
        if rotate {
            output = hadamardTransform(output)
        }
        return output
    }
}

final class DeepSeekFlashIndexer: Module {
    let configuration: DeepSeekFlashConfiguration
    let ratio: Int

    @ModuleInfo(key: "wq_b") var queryProjection: DeepSeekFlashLinear
    @ModuleInfo(key: "weights_proj") var weightsProjection: DeepSeekFlashLinear
    @ModuleInfo(key: "compressor") var compressor: DeepSeekFlashCompressor

    init(configuration: DeepSeekFlashConfiguration, ratio: Int) {
        self.configuration = configuration
        self.ratio = ratio
        _queryProjection.wrappedValue = DeepSeekFlashLinear(
            configuration.qLoraRank,
            configuration.indexHeadCount * configuration.indexHeadDimension,
            storage: .mxfp8Block128)
        _weightsProjection.wrappedValue = DeepSeekFlashLinear(
            configuration.hiddenSize, configuration.indexHeadCount, storage: .bfloat16)
        _compressor.wrappedValue = DeepSeekFlashCompressor(
            configuration: configuration,
            ratio: ratio,
            headDimension: configuration.indexHeadDimension,
            rotate: true)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        reducedQuery: MLXArray,
        startPosition: Int,
        offset: Int,
        state: DeepSeekFlashAttentionState
    ) -> MLXArray {
        let batchSize = x.dim(0)
        let sequenceLength = x.dim(1)
        let endPosition = startPosition + sequenceLength
        let compressedCount = endPosition / ratio
        guard compressedCount > 0,
              var cache = state.indexKeyValueCache,
              let compressorState = state.indexCompressor
        else {
            return MLXArray.zeros([batchSize, sequenceLength, 0], dtype: .int32)
        }

        var query = queryProjection(reducedQuery)
            .reshaped([
                batchSize,
                sequenceLength,
                configuration.indexHeadCount,
                configuration.indexHeadDimension,
            ])
        query = DeepSeekFlashRoPE.apply(
            query,
            positions: Array(startPosition ..< endPosition),
            dimension: configuration.ropeHeadDimension,
            base: configuration.compressRopeTheta,
            originalSequenceLength: configuration.originalMaxPositionEmbeddings,
            factor: configuration.ropeFactor,
            betaFast: configuration.ropeBetaFast,
            betaSlow: configuration.ropeBetaSlow)
        query = hadamardTransform(query)

        if let compressed = compressor(x, startPosition: startPosition, state: compressorState) {
            if startPosition == 0 {
                cache[0 ..< batchSize, 0 ..< compressed.dim(1)] = compressed
            } else {
                cache[0 ..< batchSize, startPosition / ratio] = compressed[0..., 0]
            }
            state.indexKeyValueCache = cache
        }

        let available = cache[0 ..< batchSize, 0 ..< compressedCount]
        var scores = MLX.einsum("bshd,btd->bsht", query, available)
        scores = MLX.maximum(scores, 0)
        let headWeights = weightsProjection(x)
            * ((1 / Float(configuration.indexHeadDimension).squareRoot())
                * (1 / Float(configuration.indexHeadCount).squareRoot()))
        scores = sum(scores * headWeights.expandedDimensions(axis: -1), axis: 2)

        if startPosition == 0 {
            var maskValues = [Float]()
            maskValues.reserveCapacity(sequenceLength * compressedCount)
            for position in 0 ..< sequenceLength {
                let visible = (position + 1) / ratio
                for compressedPosition in 0 ..< compressedCount {
                    maskValues.append(compressedPosition < visible ? 0 : -Float.infinity)
                }
            }
            scores = scores + MLXArray(maskValues, [1, sequenceLength, compressedCount])
        }

        let topK = min(configuration.indexTopK, compressedCount)
        var indices = argPartition(
            scores, kth: compressedCount - topK, axis: -1)[.ellipsis, (compressedCount - topK)...]
            .asType(.int32)
        if startPosition == 0 {
            let visible = MLXArray((0 ..< sequenceLength).map { Int32(($0 + 1) / ratio) })
                .reshaped([1, sequenceLength, 1])
            indices = MLX.where(indices .< visible, indices + Int32(offset), MLXArray(Int32(-1)))
        } else {
            indices = indices + Int32(offset)
        }
        return indices
    }
}

private func windowIndices(
    batchSize: Int,
    sequenceLength: Int,
    startPosition: Int,
    window: Int,
    imageVisibility: DeepSeekFlashImageVisibility?,
    maximumImageTokens: Int
) -> MLXArray {
    if startPosition == 0, let imageVisibility {
        let width = min(sequenceLength, window + maximumImageTokens)
        var values = [Int32]()
        values.reserveCapacity(batchSize * sequenceLength * width)
        for _ in 0 ..< batchSize {
            for token in 0 ..< sequenceLength {
                let leftExtension = max(imageVisibility.left[token] - (window - 1), 0)
                let start = max(token - (window - 1) - leftExtension, 0)
                let end = min(token + imageVisibility.right[token], sequenceLength - 1)
                let row = Array(start ... end).prefix(width)
                values.append(contentsOf: row.map(Int32.init))
                values.append(contentsOf: repeatElement(Int32(-1), count: width - row.count))
            }
        }
        return MLXArray(values, [batchSize, sequenceLength, width])
    }

    var values = [Int32]()
    values.reserveCapacity(batchSize * sequenceLength * window)
    for _ in 0 ..< batchSize {
        for token in 0 ..< sequenceLength {
            let absolute = startPosition + token
            let visibleCount = min(window, absolute + 1)
            var row: [Int]
            if startPosition > 0 {
                if absolute >= window - 1 {
                    let current = absolute % window
                    row = Array((current + 1) ..< window) + Array(0 ... current)
                } else {
                    row = Array(0 ... absolute)
                }
            } else {
                row = Array(max(0, token - window + 1) ... token)
            }
            values.append(contentsOf: row.suffix(visibleCount).map(Int32.init))
            values.append(contentsOf: repeatElement(Int32(-1), count: window - visibleCount))
        }
    }
    return MLXArray(values, [batchSize, sequenceLength, window])
}

private func compressionIndices(
    batchSize: Int,
    sequenceLength: Int,
    startPosition: Int,
    ratio: Int,
    offset: Int
) -> MLXArray {
    let count = (startPosition + sequenceLength) / ratio
    guard count > 0 else {
        return MLXArray.zeros([batchSize, sequenceLength, 0], dtype: .int32)
    }
    var values = [Int32]()
    values.reserveCapacity(batchSize * sequenceLength * count)
    for _ in 0 ..< batchSize {
        for token in 0 ..< sequenceLength {
            let visible = (startPosition + token + 1) / ratio
            for position in 0 ..< count {
                values.append(position < visible ? Int32(offset + position) : -1)
            }
        }
    }
    return MLXArray(values, [batchSize, sequenceLength, count])
}

func deepSeekFlashSparseAttention(
    query: MLXArray,
    keyValue: MLXArray,
    indices: MLXArray,
    attentionSink: MLXArray,
    scale: Float
) -> MLXArray {
    let batchSize = query.dim(0)
    let sequenceLength = query.dim(1)
    let headCount = query.dim(2)
    let headDimension = query.dim(3)
    var batches = [MLXArray]()
    for batch in 0 ..< batchSize {
        var rows = [MLXArray]()
        for token in 0 ..< sequenceLength {
            let rowIndices = indices[batch, token]
            let valid = rowIndices .>= 0
            let safeIndices = MLX.where(valid, rowIndices, MLXArray(Int32(0)))
            let selected = keyValue[batch].take(safeIndices, axis: 0)
            var logits = MLX.einsum("hd,kd->hk", query[batch, token], selected) * scale
            logits = MLX.where(
                valid.expandedDimensions(axis: 0), logits, MLXArray(-Float.infinity))
            logits = MLX.concatenated(
                [logits, attentionSink.reshaped([headCount, 1])], axis: -1)
            let probabilities = softmax(logits, axis: -1)[0..., 0 ..< rowIndices.dim(0)]
            let attended = MLX.einsum("hk,kd->hd", probabilities, selected)
            rows.append(attended)
        }
        batches.append(MLX.stacked(rows, axis: 0))
    }
    return MLX.stacked(batches, axis: 0)
        .reshaped([batchSize, sequenceLength, headCount, headDimension])
}

private func sparseAttention(
    query: MLXArray,
    keyValue: MLXArray,
    indices: MLXArray,
    attentionSink: MLXArray,
    scale: Float
) -> MLXArray {
    deepSeekFlashSparseAttention(
        query: query,
        keyValue: keyValue,
        indices: indices,
        attentionSink: attentionSink,
        scale: scale)
}
