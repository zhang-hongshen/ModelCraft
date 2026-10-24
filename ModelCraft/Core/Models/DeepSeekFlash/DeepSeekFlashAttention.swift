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

    /// Attends `x`, the tokens at `startPosition...`, to the committed window, the compressed
    /// history, and each other. The new tokens are staged in `state`; they become part of the
    /// window only when the state commits them, so a verification step can discard a rejected tail.
    func callAsFunction(
        _ x: MLXArray,
        startPosition: Int,
        state: DeepSeekFlashAttentionState,
        imageVisibility: DeepSeekFlashImageVisibility? = nil
    ) -> MLXArray {
        let batchSize = x.dim(0)
        let sequenceLength = x.dim(1)
        let window = configuration.slidingWindow

        let reducedQuery = queryNorm(queryA(x))
        var query = queryB(reducedQuery).reshaped([
            batchSize, sequenceLength,
            configuration.numAttentionHeads,
            configuration.headDimension,
        ])
        query = query * rsqrt(mean(query * query, axis: -1, keepDims: true)
            + configuration.rmsNormEpsilon)
        query = applyRoPE(query, start: startPosition)

        let currentKeyValue = applyRoPE(
            keyValueNorm(keyValue(x)), start: startPosition)
        let windows = windowIndices(
            batchSize: batchSize,
            sequenceLength: sequenceLength,
            startPosition: startPosition,
            window: window,
            imageVisibility: imageVisibility,
            maximumImageTokens: configuration.visionMaximumTokenCount)

        var cachedIndices = windows.cached.map { [$0] } ?? []
        if compressionRatio > 0 {
            if let compressor,
               let compressorState = state.compressor,
               let compressed = compressor(
                   x, startPosition: startPosition, state: compressorState)
            {
                let first = window + startPosition / compressionRatio
                state.keyValueCache[
                    0 ..< batchSize, first ..< (first + compressed.dim(1))] = compressed
            }
            if let indexer {
                cachedIndices.append(indexer(
                    x,
                    reducedQuery: reducedQuery,
                    startPosition: startPosition,
                    offset: window,
                    state: state))
            } else {
                cachedIndices.append(compressionIndices(
                    batchSize: batchSize,
                    sequenceLength: sequenceLength,
                    startPosition: startPosition,
                    ratio: compressionRatio,
                    offset: window))
            }
        }
        state.stage(currentKeyValue, startPosition: startPosition)

        var sources = [(keyValue: currentKeyValue, indices: windows.current)]
        if !cachedIndices.isEmpty {
            sources.append((
                state.keyValueCache[0 ..< batchSize],
                MLX.concatenated(cachedIndices, axis: -1)))
        }
        var output = deepSeekFlashSparseAttention(
            query: query,
            sources: sources,
            attentionSink: attentionSink,
            scale: softmaxScale)
        output = applyRoPE(
            output, start: startPosition, inverse: true)
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
        start: Int,
        inverse: Bool = false
    ) -> MLXArray {
        DeepSeekFlashRoPE.apply(
            x,
            start: start,
            dimension: configuration.ropeHeadDimension,
            base: compressionRatio > 0 ? configuration.compressRopeTheta : configuration.ropeTheta,
            originalSequenceLength: compressionRatio > 0
                ? configuration.originalMaxPositionEmbeddings : 0,
            factor: configuration.ropeFactor,
            betaFast: configuration.ropeBetaFast,
            betaSlow: configuration.ropeBetaSlow,
            inverse: inverse)
    }
}

/// The unfinished compression group of one compressor. Committing replaces the arrays rather
/// than writing into them, so a snapshot can hold on to the previous ones.
final class DeepSeekFlashCompressorState {
    let ratio: Int
    let overlapping: Bool
    /// Overlapping compressors keep the previous complete group in `0 ..< ratio` and the current
    /// one in `ratio ..< 2 * ratio`; the others keep the current group in `0 ..< ratio`.
    private(set) var keyValue: MLXArray
    private(set) var score: MLXArray
    private var staged: (keyValue: MLXArray, score: MLXArray, startPosition: Int)?

    init(batchSize: Int, ratio: Int, headDimension: Int, overlapping: Bool) {
        self.ratio = ratio
        self.overlapping = overlapping
        let coefficient = overlapping ? 2 : 1
        keyValue = MLXArray.zeros(
            [batchSize, coefficient * ratio, coefficient * headDimension], dtype: .float32)
        score = MLXArray.full(
            [batchSize, coefficient * ratio, coefficient * headDimension],
            values: MLXArray(-Float.infinity), dtype: .float32)
    }

    var arrays: [MLXArray] { [keyValue, score] }

    /// The current group's committed tokens followed by `keyValue` and `score`, so the result
    /// starts at a group boundary.
    func pending(
        keyValue newKeyValue: MLXArray,
        score newScore: MLXArray,
        startPosition: Int
    ) -> (keyValue: MLXArray, score: MLXArray) {
        let count = startPosition % ratio
        guard count > 0 else { return (newKeyValue, newScore) }
        let offset = overlapping ? ratio : 0
        let batchSize = newKeyValue.dim(0)
        return (
            MLX.concatenated(
                [keyValue[0 ..< batchSize, offset ..< (offset + count)], newKeyValue], axis: 1),
            MLX.concatenated(
                [score[0 ..< batchSize, offset ..< (offset + count)], newScore], axis: 1))
    }

    /// The previous complete group, which overlapping compressors blend into the next one.
    func previousGroup(batchSize: Int) -> (keyValue: MLXArray, score: MLXArray) {
        (keyValue[0 ..< batchSize, 0 ..< ratio], score[0 ..< batchSize, 0 ..< ratio])
    }

    func stage(keyValue: MLXArray, score: MLXArray, startPosition: Int) {
        staged = (keyValue, score, startPosition)
    }

    /// Advances the group by the first `count` staged tokens.
    func commit(count: Int) {
        guard let staged else { return }
        self.staged = nil
        let batchSize = staged.keyValue.dim(0)
        let tokens = pending(
            keyValue: staged.keyValue[0..., 0 ..< count],
            score: staged.score[0..., 0 ..< count],
            startPosition: staged.startPosition)
        let length = tokens.keyValue.dim(1)
        let remainder = length % ratio
        let cutoff = length - remainder

        var keyValueParts = [MLXArray]()
        var scoreParts = [MLXArray]()
        if overlapping {
            if cutoff > 0 {
                keyValueParts.append(tokens.keyValue[0..., (cutoff - ratio) ..< cutoff])
                scoreParts.append(tokens.score[0..., (cutoff - ratio) ..< cutoff])
            } else {
                let previous = previousGroup(batchSize: batchSize)
                keyValueParts.append(previous.keyValue)
                scoreParts.append(previous.score)
            }
        }
        if remainder > 0 {
            keyValueParts.append(tokens.keyValue[0..., cutoff...])
            scoreParts.append(tokens.score[0..., cutoff...])
        }
        if remainder < ratio {
            let width = keyValue.dim(2)
            keyValueParts.append(MLXArray.zeros(
                [batchSize, ratio - remainder, width], dtype: .float32))
            scoreParts.append(MLXArray.full(
                [batchSize, ratio - remainder, width],
                values: MLXArray(-Float.infinity), dtype: .float32))
        }
        keyValue = MLX.concatenated(keyValueParts, axis: 1)
        score = MLX.concatenated(scoreParts, axis: 1)
    }

    func restore(keyValue: MLXArray, score: MLXArray) {
        self.keyValue = keyValue
        self.score = score
        staged = nil
    }

    /// Empties the group for a sequence that starts over.
    func reset() {
        restore(
            keyValue: MLXArray.zeros(like: keyValue),
            score: MLXArray.full(
                keyValue.shape, values: MLXArray(-Float.infinity), dtype: .float32))
    }
}

/// One layer's attention memory: a ring of the last `slidingWindow` key-values followed by the
/// compressed history. Compressed rows are written as soon as their group completes; a row written
/// by a rejected token is rewritten before any later token can see it, so only the ring and the
/// compressor groups need committing and snapshots.
final class DeepSeekFlashAttentionState {
    struct Snapshot {
        let window: MLXArray
        let compressor: (keyValue: MLXArray, score: MLXArray)?
        let indexCompressor: (keyValue: MLXArray, score: MLXArray)?
    }

    let window: Int
    var keyValueCache: MLXArray
    var indexKeyValueCache: MLXArray?
    let compressor: DeepSeekFlashCompressorState?
    let indexCompressor: DeepSeekFlashCompressorState?
    private var staged: (keyValue: MLXArray, startPosition: Int)?

    init(
        configuration: DeepSeekFlashConfiguration,
        layerID: Int,
        batchSize: Int,
        maximumSequenceLength: Int
    ) {
        window = configuration.slidingWindow
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

    var arrays: [MLXArray] {
        [keyValueCache] + [indexKeyValueCache].compactMap { $0 }
            + (compressor?.arrays ?? []) + (indexCompressor?.arrays ?? [])
    }

    func stage(_ keyValue: MLXArray, startPosition: Int) {
        staged = (keyValue, startPosition)
    }

    /// Adds the first `count` staged tokens to the window and the compressor groups.
    func commit(count: Int) {
        if let staged {
            storeWindow(staged.keyValue[0..., 0 ..< count], startPosition: staged.startPosition)
            self.staged = nil
        }
        compressor?.commit(count: count)
        indexCompressor?.commit(count: count)
    }

    /// Writes the key-values of positions `startPosition...` into their ring slots.
    func storeWindow(_ value: MLXArray, startPosition: Int) {
        let batchSize = value.dim(0)
        let count = min(value.dim(1), window)
        let tail = value[0..., (value.dim(1) - count)...]
        let slot = (startPosition + value.dim(1) - count) % window
        if slot + count <= window {
            keyValueCache[0 ..< batchSize, slot ..< (slot + count)] = tail
        } else {
            let split = window - slot
            keyValueCache[0 ..< batchSize, slot ..< window] = tail[0..., 0 ..< split]
            keyValueCache[0 ..< batchSize, 0 ..< (count - split)] = tail[0..., split...]
        }
    }

    func snapshot() -> Snapshot {
        // `* 1` copies the ring so the snapshot does not keep the whole cache buffer alive.
        Snapshot(
            window: keyValueCache[0..., 0 ..< window] * 1,
            compressor: compressor.map { ($0.keyValue, $0.score) },
            indexCompressor: indexCompressor.map { ($0.keyValue, $0.score) })
    }

    func restore(_ snapshot: Snapshot) {
        keyValueCache[0..., 0 ..< window] = snapshot.window
        if let state = snapshot.compressor {
            compressor?.restore(keyValue: state.keyValue, score: state.score)
        }
        if let state = snapshot.indexCompressor {
            indexCompressor?.restore(keyValue: state.keyValue, score: state.score)
        }
        staged = nil
    }

    func reset() {
        compressor?.reset()
        indexCompressor?.reset()
        staged = nil
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

    /// Stages the tokens at `startPosition...` in `state` and returns the groups they complete,
    /// beginning with group `startPosition / ratio`, or `nil` when none completes.
    func callAsFunction(
        _ x: MLXArray,
        startPosition: Int,
        state: DeepSeekFlashCompressorState
    ) -> MLXArray? {
        let batchSize = x.dim(0)
        let sequenceLength = x.dim(1)
        let coefficient = overlapping ? 2 : 1
        let value = x.asType(.float32)
        let keyValue = keyValueProjection(value).asType(.float32)
        let groupPositions = MLXArray((startPosition ..< (startPosition + sequenceLength)).map {
            Int32($0 % ratio)
        })
        let scores = gateProjection(value).asType(.float32)
            + absolutePositionEmbedding.take(groupPositions, axis: 0)
        state.stage(keyValue: keyValue, score: scores, startPosition: startPosition)

        let tokens = state.pending(
            keyValue: keyValue, score: scores, startPosition: startPosition)
        let groupCount = tokens.keyValue.dim(1) / ratio
        guard groupCount > 0 else { return nil }
        let cutoff = groupCount * ratio
        var groupedKeyValue = tokens.keyValue[0..., 0 ..< cutoff]
            .reshaped([batchSize, groupCount, ratio, coefficient * headDimension])
        var groupedScore = tokens.score[0..., 0 ..< cutoff]
            .reshaped([batchSize, groupCount, ratio, coefficient * headDimension])

        if overlapping {
            let previous = state.previousGroup(batchSize: batchSize)
            var previousKeyValue = [previous.keyValue.expandedDimensions(axis: 1)]
            var previousScore = [previous.score.expandedDimensions(axis: 1)]
            if groupCount > 1 {
                previousKeyValue.append(groupedKeyValue[0..., 0 ..< (groupCount - 1)])
                previousScore.append(groupedScore[0..., 0 ..< (groupCount - 1)])
            }
            groupedKeyValue = MLX.concatenated([
                MLX.concatenated(previousKeyValue, axis: 1)[.ellipsis, 0 ..< headDimension],
                groupedKeyValue[.ellipsis, headDimension...],
            ], axis: 2)
            groupedScore = MLX.concatenated([
                MLX.concatenated(previousScore, axis: 1)[.ellipsis, 0 ..< headDimension],
                groupedScore[.ellipsis, headDimension...],
            ], axis: 2)
        }
        let compressed = sum(groupedKeyValue * softmax(groupedScore, axis: 2), axis: 2)

        var output = norm(compressed.asType(x.dtype))
        output = DeepSeekFlashRoPE.apply(
            output,
            start: startPosition - startPosition % ratio,
            step: ratio,
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
        let compressedCount = (startPosition + sequenceLength) / ratio
        guard var cache = state.indexKeyValueCache,
              let compressorState = state.indexCompressor
        else {
            return MLXArray.zeros([batchSize, sequenceLength, 0], dtype: .int32)
        }

        if let compressed = compressor(x, startPosition: startPosition, state: compressorState) {
            let first = startPosition / ratio
            cache[0 ..< batchSize, first ..< (first + compressed.dim(1))] = compressed
            state.indexKeyValueCache = cache
        }
        guard compressedCount > 0 else {
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
            start: startPosition,
            dimension: configuration.ropeHeadDimension,
            base: configuration.compressRopeTheta,
            originalSequenceLength: configuration.originalMaxPositionEmbeddings,
            factor: configuration.ropeFactor,
            betaFast: configuration.ropeBetaFast,
            betaSlow: configuration.ropeBetaSlow)
        query = hadamardTransform(query)

        let available = cache[0 ..< batchSize, 0 ..< compressedCount]
        var scores = MLX.einsum("bshd,btd->bsht", query, available)
        scores = MLX.maximum(scores, 0)
        let headWeights = weightsProjection(x)
            * ((1 / Float(configuration.indexHeadDimension).squareRoot())
                * (1 / Float(configuration.indexHeadCount).squareRoot()))
        scores = sum(scores * headWeights.expandedDimensions(axis: -1), axis: 2)

        // A token sees the groups completed up to and including itself.
        let visible = MLXArray((0 ..< sequenceLength).map {
            Int32((startPosition + $0 + 1) / ratio)
        }).reshaped([1, sequenceLength, 1])
        let groups = MLXArray((0 ..< compressedCount).map(Int32.init))
            .reshaped([1, 1, compressedCount])
        scores = MLX.where(groups .< visible, scores, MLXArray(-Float.infinity))

        let topK = min(configuration.indexTopK, compressedCount)
        let indices = argPartition(
            scores, kth: compressedCount - topK, axis: -1)[.ellipsis, (compressedCount - topK)...]
            .asType(.int32)
        return MLX.where(indices .< visible, indices + Int32(offset), MLXArray(Int32(-1)))
    }
}

/// Window indices for the tokens at `startPosition...`: `cached` points into the ring of committed
/// positions, `current` into the new tokens themselves.
private func windowIndices(
    batchSize: Int,
    sequenceLength: Int,
    startPosition: Int,
    window: Int,
    imageVisibility: DeepSeekFlashImageVisibility?,
    maximumImageTokens: Int
) -> (cached: MLXArray?, current: MLXArray) {
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
        return (nil, MLXArray(values, [batchSize, sequenceLength, width]))
    }

    let cachedWidth = min(startPosition, window - 1)
    let currentWidth = min(sequenceLength, window)
    var cached = [Int32]()
    var current = [Int32]()
    cached.reserveCapacity(batchSize * sequenceLength * cachedWidth)
    current.reserveCapacity(batchSize * sequenceLength * currentWidth)
    for _ in 0 ..< batchSize {
        for token in 0 ..< sequenceLength {
            let absolute = startPosition + token
            let first = max(0, absolute - window + 1)
            let cachedRow = (first ..< max(first, startPosition)).map { Int32($0 % window) }
            cached.append(contentsOf: cachedRow)
            cached.append(contentsOf: repeatElement(Int32(-1), count: cachedWidth - cachedRow.count))
            let currentRow = (max(first, startPosition) ... absolute).map {
                Int32($0 - startPosition)
            }
            current.append(contentsOf: currentRow)
            current.append(contentsOf: repeatElement(
                Int32(-1), count: currentWidth - currentRow.count))
        }
    }
    return (
        cachedWidth > 0 ? MLXArray(cached, [batchSize, sequenceLength, cachedWidth]) : nil,
        MLXArray(current, [batchSize, sequenceLength, currentWidth]))
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
    let visible = MLXArray((0 ..< sequenceLength).map {
        Int32((startPosition + $0 + 1) / ratio)
    }).reshaped([1, sequenceLength, 1])
    let groups = MLXArray((0 ..< count).map(Int32.init)).reshaped([1, 1, count])
    return MLX.broadcast(
        MLX.where(groups .< visible, groups + Int32(offset), MLXArray(Int32(-1))),
        to: [batchSize, sequenceLength, count])
}

/// Attends each token to the rows its indices select from each source; `-1` marks an unused slot.
/// Tokens are processed in chunks so the gathered rows stay small during long prefills.
func deepSeekFlashSparseAttention(
    query: MLXArray,
    sources: [(keyValue: MLXArray, indices: MLXArray)],
    attentionSink: MLXArray,
    scale: Float
) -> MLXArray {
    let batchSize = query.dim(0)
    let sequenceLength = query.dim(1)
    let headCount = query.dim(2)
    let headDimension = query.dim(3)
    let sources = sources.filter { $0.indices.dim(-1) > 0 }
    let chunkSize = 64

    var chunks = [MLXArray]()
    for start in stride(from: 0, to: sequenceLength, by: chunkSize) {
        let end = min(start + chunkSize, sequenceLength)
        let length = end - start
        var selected = [MLXArray]()
        var valid = [MLXArray]()
        for source in sources {
            let rows = source.indices[0..., start ..< end]
            let isValid = rows .>= 0
            let safeRows = MLX.where(isValid, rows, MLXArray(Int32(0)))
            let width = rows.dim(-1)
            selected.append(MLX.stacked((0 ..< batchSize).map { batch in
                source.keyValue[batch].take(safeRows[batch].flattened(), axis: 0)
                    .reshaped([length, width, headDimension])
            }, axis: 0))
            valid.append(isValid)
        }
        let keyValue = MLX.concatenated(selected, axis: 2)
        let mask = MLX.concatenated(valid, axis: 2)
        var logits = MLX.einsum("blhd,blkd->blhk", query[0..., start ..< end], keyValue) * scale
        logits = MLX.where(
            mask.expandedDimensions(axis: 2), logits, MLXArray(-Float.infinity))
        logits = MLX.concatenated([
            logits,
            MLX.broadcast(
                attentionSink.reshaped([1, 1, headCount, 1]),
                to: [batchSize, length, headCount, 1]),
        ], axis: -1)
        let probabilities = softmax(logits, axis: -1)[.ellipsis, 0 ..< keyValue.dim(2)]
        chunks.append(MLX.einsum("blhk,blkd->blhd", probabilities, keyValue))
    }
    return MLX.concatenated(chunks, axis: 1)
}
