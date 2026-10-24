//
//  DeepSeekFlashDSpark.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import MLX
import MLXNN

struct DeepSeekFlashDSparkOutput {
    let tokenIDs: MLXArray
    let logits: MLXArray
    let confidence: MLXArray
}

final class DeepSeekFlashDSparkAttention: DeepSeekFlashAttention {
    /// Writes the main model's key-values for the committed positions `startPosition...`
    /// into the draft window.
    func observe(
        mainHidden: MLXArray,
        startPosition: Int,
        state: DeepSeekFlashAttentionState
    ) {
        precondition(compressionRatio == 0)
        state.storeWindow(
            applyRoPE(keyValueNorm(keyValue(mainHidden)), start: startPosition),
            startPosition: startPosition)
    }

    /// Attends the draft block placed at `startPosition`, the first uncommitted position, to the
    /// main model's window and to itself.
    func draft(
        _ x: MLXArray,
        startPosition: Int,
        state: DeepSeekFlashAttentionState
    ) -> MLXArray {
        precondition(compressionRatio == 0)
        let batchSize = x.dim(0)
        let blockSize = x.dim(1)
        let window = configuration.slidingWindow
        let reducedQuery = queryNorm(queryA(x))
        var query = queryB(reducedQuery).reshaped([
            batchSize,
            blockSize,
            configuration.numAttentionHeads,
            configuration.headDimension,
        ])
        query = query * rsqrt(mean(query * query, axis: -1, keepDims: true)
            + configuration.rmsNormEpsilon)
        query = applyRoPE(query, start: startPosition)
        let draftKeyValue = applyRoPE(
            keyValueNorm(keyValue(x)), start: startPosition)

        let mainCount = min(window, startPosition)
        let mainIndices = MLX.broadcast(
            MLXArray((0 ..< mainCount).map(Int32.init)).reshaped([1, 1, mainCount]),
            to: [batchSize, blockSize, mainCount])
        let draftIndices = MLX.broadcast(
            MLXArray((0 ..< blockSize).map(Int32.init)).reshaped([1, 1, blockSize]),
            to: [batchSize, blockSize, blockSize])
        var output = deepSeekFlashSparseAttention(
            query: query,
            sources: [
                (state.keyValueCache[0 ..< batchSize, 0 ..< window], mainIndices),
                (draftKeyValue, draftIndices),
            ],
            attentionSink: attentionSink,
            scale: softmaxScale)
        output = applyRoPE(output, start: startPosition, inverse: true)
        return projectOutput(output)
    }
}

final class DeepSeekFlashMarkovHead: Module {
    @ModuleInfo(key: "markov_w1") var embedding: DeepSeekFlashEmbedding
    @ModuleInfo(key: "markov_w2") var head: DeepSeekFlashHead

    init(configuration: DeepSeekFlashConfiguration) {
        _embedding.wrappedValue = DeepSeekFlashEmbedding(
            vocabularySize: configuration.vocabularySize,
            dimensions: configuration.dsparkMarkovRank)
        _head.wrappedValue = DeepSeekFlashHead(
            vocabularySize: configuration.vocabularySize,
            dimensions: configuration.dsparkMarkovRank)
        super.init()
    }

    func callAsFunction(_ tokenIDs: MLXArray) -> (logits: MLXArray, embedding: MLXArray) {
        let value = embedding(tokenIDs)
        return (head(value, fullLogits: true), value)
    }
}

final class DeepSeekFlashConfidenceHead: Module {
    @ModuleInfo(key: "proj") var projection: DeepSeekFlashLinear

    init(configuration: DeepSeekFlashConfiguration) {
        _projection.wrappedValue = DeepSeekFlashLinear(
            configuration.hiddenSize + configuration.dsparkMarkovRank,
            1,
            storage: .bfloat16)
        super.init()
    }

    func callAsFunction(_ hidden: MLXArray, markovEmbedding: MLXArray) -> MLXArray {
        projection(MLX.concatenated([hidden, markovEmbedding], axis: -1).asType(.float32))
            .squeezed(axis: -1)
    }
}

final class DeepSeekFlashDSparkBlock: Module {
    let stageID: Int
    let layerID: Int
    let configuration: DeepSeekFlashConfiguration

    @ModuleInfo(key: "attn") var attention: DeepSeekFlashDSparkAttention
    @ModuleInfo(key: "ffn") var feedForward: DeepSeekFlashMoE
    @ModuleInfo(key: "attn_norm") var attentionNorm: DeepSeekFlashRMSNorm
    @ModuleInfo(key: "ffn_norm") var feedForwardNorm: DeepSeekFlashRMSNorm
    @ParameterInfo(key: "hc_attn_fn") var attentionHCFunction: MLXArray
    @ParameterInfo(key: "hc_ffn_fn") var feedForwardHCFunction: MLXArray
    @ParameterInfo(key: "hc_attn_base") var attentionHCBase: MLXArray
    @ParameterInfo(key: "hc_ffn_base") var feedForwardHCBase: MLXArray
    @ParameterInfo(key: "hc_attn_scale") var attentionHCScale: MLXArray
    @ParameterInfo(key: "hc_ffn_scale") var feedForwardHCScale: MLXArray

    @ModuleInfo(key: "main_proj") var mainProjection: DeepSeekFlashLinear?
    @ModuleInfo(key: "main_norm") var mainNorm: DeepSeekFlashRMSNorm?
    @ModuleInfo(key: "norm") var outputNorm: DeepSeekFlashRMSNorm?
    @ModuleInfo(key: "markov_head") var markovHead: DeepSeekFlashMarkovHead?
    @ModuleInfo(key: "confidence_head") var confidenceHead: DeepSeekFlashConfidenceHead?
    @ParameterInfo(key: "hc_head_fn") var headHCFunction: MLXArray?
    @ParameterInfo(key: "hc_head_base") var headHCBase: MLXArray?
    @ParameterInfo(key: "hc_head_scale") var headHCScale: MLXArray?
    var embedding: DeepSeekFlashEmbedding?
    var head: DeepSeekFlashHead?

    init(stageID: Int, configuration: DeepSeekFlashConfiguration, streamsExperts: Bool) {
        self.stageID = stageID
        self.configuration = configuration
        layerID = configuration.numHiddenLayers + stageID
        let multiplier = configuration.hyperConnectionMultiplier
        let mixingSize = (2 + multiplier) * multiplier
        let hyperConnectionDimensions = multiplier * configuration.hiddenSize

        _attention.wrappedValue = DeepSeekFlashDSparkAttention(
            layerID: layerID, configuration: configuration)
        _feedForward.wrappedValue = DeepSeekFlashMoE(
            layerID: layerID, configuration: configuration, streamsExperts: streamsExperts)
        _attentionNorm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.hiddenSize, epsilon: configuration.rmsNormEpsilon)
        _feedForwardNorm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.hiddenSize, epsilon: configuration.rmsNormEpsilon)
        _attentionHCFunction.wrappedValue = MLXArray.zeros(
            [mixingSize, hyperConnectionDimensions], dtype: .float32)
        _feedForwardHCFunction.wrappedValue = MLXArray.zeros(
            [mixingSize, hyperConnectionDimensions], dtype: .float32)
        _attentionHCBase.wrappedValue = MLXArray.zeros([mixingSize], dtype: .float32)
        _feedForwardHCBase.wrappedValue = MLXArray.zeros([mixingSize], dtype: .float32)
        _attentionHCScale.wrappedValue = MLXArray.zeros([3], dtype: .float32)
        _feedForwardHCScale.wrappedValue = MLXArray.zeros([3], dtype: .float32)

        if stageID == 0 {
            _mainProjection.wrappedValue = DeepSeekFlashLinear(
                configuration.hiddenSize * configuration.dsparkTargetLayerIDs.count,
                configuration.hiddenSize,
                storage: .mxfp8Block128)
            _mainNorm.wrappedValue = DeepSeekFlashRMSNorm(
                dimensions: configuration.hiddenSize, epsilon: configuration.rmsNormEpsilon)
        } else {
            _mainProjection.wrappedValue = nil
            _mainNorm.wrappedValue = nil
        }

        if stageID == configuration.numNextPredictLayers - 1 {
            _outputNorm.wrappedValue = DeepSeekFlashRMSNorm(
                dimensions: configuration.hiddenSize, epsilon: configuration.rmsNormEpsilon)
            _markovHead.wrappedValue = DeepSeekFlashMarkovHead(configuration: configuration)
            _confidenceHead.wrappedValue = DeepSeekFlashConfidenceHead(configuration: configuration)
            _headHCFunction.wrappedValue = MLXArray.zeros(
                [multiplier, hyperConnectionDimensions], dtype: .float32)
            _headHCBase.wrappedValue = MLXArray.zeros([multiplier], dtype: .float32)
            _headHCScale.wrappedValue = MLXArray.zeros([1], dtype: .float32)
        } else {
            _outputNorm.wrappedValue = nil
            _markovHead.wrappedValue = nil
            _confidenceHead.wrappedValue = nil
            _headHCFunction.wrappedValue = nil
            _headHCBase.wrappedValue = nil
            _headHCScale.wrappedValue = nil
        }
        super.init()
    }

    /// Projects the main model's target-layer hidden states for the draft windows.
    func projectMain(_ mainHidden: MLXArray) -> MLXArray {
        mainNorm!(mainProjection!(mainHidden))
    }

    /// The draft block: the current token followed by noise tokens for the positions to predict.
    func prepare(currentTokenIDs: MLXArray) -> MLXArray {
        let batchSize = currentTokenIDs.dim(0)
        let noise = MLXArray.full(
            [batchSize, configuration.dsparkBlockSize - 1],
            values: MLXArray(Int32(configuration.dsparkNoiseTokenID)),
            dtype: .int32)
        let draftIDs = MLX.concatenated(
            [currentTokenIDs.reshaped([batchSize, 1]).asType(.int32), noise], axis: 1)
        let hidden = embedding!(draftIDs).expandedDimensions(axis: 2)
        return MLX.repeated(
            hidden, count: configuration.hyperConnectionMultiplier, axis: 2)
    }

    func callAsFunction(
        _ x: MLXArray,
        startPosition: Int,
        inputIDs: MLXArray,
        state: DeepSeekFlashAttentionState
    ) throws -> MLXArray {
        var residual = x
        var connection = DeepSeekFlashHyperConnection.pre(
            x,
            function: attentionHCFunction,
            scale: attentionHCScale,
            base: attentionHCBase,
            configuration: configuration)
        var hidden = attentionNorm(connection.hidden)
        hidden = attention.draft(
            hidden,
            startPosition: startPosition,
            state: state)
        hidden = DeepSeekFlashHyperConnection.post(
            hidden,
            residual: residual,
            post: connection.post,
            combination: connection.combination)

        residual = hidden
        connection = DeepSeekFlashHyperConnection.pre(
            hidden,
            function: feedForwardHCFunction,
            scale: feedForwardHCScale,
            base: feedForwardHCBase,
            configuration: configuration)
        hidden = feedForwardNorm(connection.hidden)
        hidden = try feedForward(
            hidden,
            inputIDs: inputIDs)
        return DeepSeekFlashHyperConnection.post(
            hidden,
            residual: residual,
            post: connection.post,
            combination: connection.combination)
    }

    func finish(
        _ x: MLXArray,
        inputIDs: MLXArray,
        temperature: Float
    ) -> DeepSeekFlashDSparkOutput {
        var hidden = DeepSeekFlashHyperConnection.head(
            x,
            function: headHCFunction!,
            scale: headHCScale!,
            base: headHCBase!,
            configuration: configuration)
        var logits = head!(outputNorm!(hidden), fullLogits: true)
        let currentIDs = inputIDs.reshaped([inputIDs.dim(0), -1])[0..., -1]
            .reshaped([inputIDs.dim(0), 1])
        var outputIDs = MLXArray.zeros(
            [inputIDs.dim(0), configuration.dsparkBlockSize + 1], dtype: .int32)
        outputIDs[0..., 0] = currentIDs[0..., 0].asType(.int32)
        var markovEmbeddings = [MLXArray]()
        for index in 0 ..< configuration.dsparkBlockSize {
            let markov = markovHead!(outputIDs[0..., index])
            logits[0..., index] = logits[0..., index] + markov.logits
            markovEmbeddings.append(markov.embedding)
            outputIDs[0..., index + 1] = DeepSeekFlashSampler.sample(
                logits: logits[0..., index], temperature: temperature)
        }
        let markovEmbedding = MLX.stacked(markovEmbeddings, axis: 1)
        let confidence = confidenceHead!(hidden, markovEmbedding: markovEmbedding)
        return DeepSeekFlashDSparkOutput(
            tokenIDs: outputIDs,
            logits: logits,
            confidence: confidence)
    }
}

extension DeepSeekFlashTransformer {
    /// Adds the committed positions `startPosition...` to every draft window. `mainHidden` holds
    /// the target layers' hidden states for those positions.
    func observeDSpark(
        mainHidden: MLXArray,
        startPosition: Int,
        cache: DeepSeekFlashCache
    ) {
        let projectedMain = mtp[0].projectMain(mainHidden)
        for (stageID, block) in mtp.enumerated() {
            block.attention.observe(
                mainHidden: projectedMain,
                startPosition: startPosition,
                state: cache.dsparkStates[stageID])
        }
    }

    /// Drafts the tokens that follow `currentTokenIDs`, which sits at `startPosition`, the first
    /// position not yet committed.
    func draft(
        currentTokenIDs: MLXArray,
        startPosition: Int,
        cache: DeepSeekFlashCache,
        temperature: Float
    ) throws -> DeepSeekFlashDSparkOutput {
        var hidden = mtp[0].prepare(currentTokenIDs: currentTokenIDs)
        for (stageID, block) in mtp.enumerated() {
            hidden = try block(
                hidden,
                startPosition: startPosition,
                inputIDs: currentTokenIDs,
                state: cache.dsparkStates[stageID])
        }
        return mtp.last!.finish(
            hidden, inputIDs: currentTokenIDs, temperature: temperature)
    }
}
