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
    func callAsFunction(
        _ x: MLXArray,
        startPosition: Int,
        mainHidden: MLXArray,
        state: DeepSeekFlashAttentionState
    ) -> MLXArray {
        precondition(compressionRatio == 0)
        let batchSize = mainHidden.dim(0)
        let mainSequenceLength = mainHidden.dim(1)
        let window = configuration.slidingWindow
        let mainKeyValue = applyRoPE(
            keyValueNorm(keyValue(mainHidden)), start: startPosition)

        if startPosition == 0 {
            if mainSequenceLength <= window {
                state.keyValueCache[0 ..< batchSize, 0 ..< mainSequenceLength] = mainKeyValue
            } else {
                let cutoff = mainSequenceLength % window
                let tail = mainKeyValue[0..., (mainSequenceLength - window)...]
                state.keyValueCache[0 ..< batchSize, cutoff ..< window] =
                    tail[0..., 0 ..< (window - cutoff)]
                if cutoff > 0 {
                    state.keyValueCache[0 ..< batchSize, 0 ..< cutoff] =
                        tail[0..., (window - cutoff)...]
                }
            }
            return x
        }

        let blockSize = x.dim(1)
        let draftStart = startPosition + mainSequenceLength
        let reducedQuery = queryNorm(queryA(x))
        var query = queryB(reducedQuery).reshaped([
            batchSize,
            blockSize,
            configuration.numAttentionHeads,
            configuration.headDimension,
        ])
        query = query * rsqrt(mean(query * query, axis: -1, keepDims: true)
            + configuration.rmsNormEpsilon)
        query = applyRoPE(query, start: draftStart)
        let draftKeyValue = applyRoPE(
            keyValueNorm(keyValue(x)), start: draftStart)

        state.keyValueCache[0 ..< batchSize, startPosition % window] = mainKeyValue[0..., 0]
        let allKeyValue = MLX.concatenated(
            [state.keyValueCache[0 ..< batchSize, 0 ..< window], draftKeyValue], axis: 1)
        var indexValues = [Int32]()
        let mainCount = min(window, startPosition + 1)
        for _ in 0 ..< batchSize {
            for _ in 0 ..< blockSize {
                indexValues.append(contentsOf: (0 ..< mainCount).map(Int32.init))
                indexValues.append(contentsOf: (0 ..< blockSize).map { Int32(window + $0) })
            }
        }
        let indices = MLXArray(
            indexValues,
            [batchSize, blockSize, mainCount + blockSize])
        var output = deepSeekFlashSparseAttention(
            query: query,
            keyValue: allKeyValue,
            indices: indices,
            attentionSink: attentionSink,
            scale: softmaxScale)
        output = applyRoPE(output, start: draftStart, inverse: true)
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

    init(stageID: Int, configuration: DeepSeekFlashConfiguration) {
        self.stageID = stageID
        self.configuration = configuration
        layerID = configuration.numHiddenLayers + stageID
        let multiplier = configuration.hyperConnectionMultiplier
        let mixingSize = (2 + multiplier) * multiplier
        let hyperConnectionDimensions = multiplier * configuration.hiddenSize

        _attention.wrappedValue = DeepSeekFlashDSparkAttention(
            layerID: layerID, configuration: configuration)
        _feedForward.wrappedValue = DeepSeekFlashMoE(
            layerID: layerID, configuration: configuration)
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

    func prepare(
        mainHidden: MLXArray,
        inputIDs: MLXArray
    ) -> (hidden: MLXArray, mainHidden: MLXArray) {
        let projectedMain = mainNorm!(mainProjection!(mainHidden))
        let currentIDs = inputIDs.reshaped([inputIDs.dim(0), -1])[0..., -1]
            .reshaped([inputIDs.dim(0), 1])
        let noise = MLXArray.full(
            [inputIDs.dim(0), configuration.dsparkBlockSize - 1],
            values: MLXArray(Int32(configuration.dsparkNoiseTokenID)),
            dtype: .int32)
        let draftIDs = MLX.concatenated([currentIDs.asType(.int32), noise], axis: 1)
        var hidden = embedding!(draftIDs).expandedDimensions(axis: 2)
        hidden = MLX.repeated(
            hidden, count: configuration.hyperConnectionMultiplier, axis: 2)
        return (hidden, projectedMain)
    }

    func callAsFunction(
        _ x: MLXArray,
        startPosition: Int,
        inputIDs: MLXArray,
        mainHidden: MLXArray,
        state: DeepSeekFlashAttentionState
    ) -> MLXArray {
        if startPosition == 0 {
            return attention(
                x,
                startPosition: startPosition,
                mainHidden: mainHidden,
                state: state)
        }

        var residual = x
        var connection = DeepSeekFlashHyperConnection.pre(
            x,
            function: attentionHCFunction,
            scale: attentionHCScale,
            base: attentionHCBase,
            configuration: configuration)
        var hidden = attentionNorm(connection.hidden)
        hidden = attention(
            hidden,
            startPosition: startPosition,
            mainHidden: mainHidden,
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
        hidden = feedForward(
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
    func forwardSpeculative(
        inputIDs: MLXArray,
        mainHidden: MLXArray,
        startPosition: Int,
        temperature: Float = 1
    ) throws -> DeepSeekFlashDSparkOutput? {
        if startPosition == 0 || dsparkAttentionStates.count != configuration.numNextPredictLayers {
            dsparkAttentionStates = (0 ..< configuration.numNextPredictLayers).map { stageID in
                DeepSeekFlashAttentionState(
                    configuration: configuration,
                    layerID: configuration.numHiddenLayers + stageID,
                    batchSize: inputIDs.dim(0),
                    maximumSequenceLength: maximumSequenceLength)
            }
        }

        let prepared = mtp[0].prepare(
            mainHidden: mainHidden,
            inputIDs: inputIDs)
        var hidden = prepared.hidden
        let projectedMain = prepared.mainHidden
        for (stageID, block) in mtp.enumerated() {
            hidden = block(
                hidden,
                startPosition: startPosition,
                inputIDs: inputIDs,
                mainHidden: projectedMain,
                state: dsparkAttentionStates[stageID])
            eval(hidden)
        }
        guard startPosition > 0 else { return nil }
        return mtp.last!.finish(
            hidden, inputIDs: inputIDs, temperature: temperature)
    }
}
