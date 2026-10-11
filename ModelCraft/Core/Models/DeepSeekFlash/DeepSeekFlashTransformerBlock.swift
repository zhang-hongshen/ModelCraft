//
//  DeepSeekFlashTransformerBlock.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import MLX
import MLXNN


final class DeepSeekFlashTransformerBlock: Module {
    let layerID: Int
    let configuration: DeepSeekFlashConfiguration

    @ModuleInfo(key: "attn") var attention: DeepSeekFlashAttention
    @ModuleInfo(key: "attn_norm") var attentionNorm: DeepSeekFlashRMSNorm
    @ModuleInfo(key: "ffn") var feedForward: DeepSeekFlashMoE
    @ModuleInfo(key: "ffn_norm") var feedForwardNorm: DeepSeekFlashRMSNorm
    @ParameterInfo(key: "hc_attn_base") var attentionHCBase: MLXArray
    @ParameterInfo(key: "hc_attn_fn") var attentionHCFunction: MLXArray
    @ParameterInfo(key: "hc_attn_scale") var attentionHCScale: MLXArray
    @ParameterInfo(key: "hc_ffn_base") var feedForwardHCBase: MLXArray
    @ParameterInfo(key: "hc_ffn_fn") var feedForwardHCFunction: MLXArray
    @ParameterInfo(key: "hc_ffn_scale") var feedForwardHCScale: MLXArray

    init(layerID: Int, configuration: DeepSeekFlashConfiguration) {
        self.layerID = layerID
        self.configuration = configuration
        let multiplier = configuration.hyperConnectionMultiplier
        let mixingSize = (2 + multiplier) * multiplier
        let hiddenSize = multiplier * configuration.hiddenSize
        _attention.wrappedValue = DeepSeekFlashAttention(
            layerID: layerID, configuration: configuration)
        _feedForward.wrappedValue = DeepSeekFlashMoE(
            layerID: layerID, configuration: configuration)
        _attentionNorm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.hiddenSize, epsilon: configuration.rmsNormEpsilon)
        _feedForwardNorm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.hiddenSize, epsilon: configuration.rmsNormEpsilon)
        _attentionHCFunction.wrappedValue = MLXArray.zeros(
            [mixingSize, hiddenSize], dtype: .float32)
        _feedForwardHCFunction.wrappedValue = MLXArray.zeros(
            [mixingSize, hiddenSize], dtype: .float32)
        _attentionHCBase.wrappedValue = MLXArray.zeros([mixingSize], dtype: .float32)
        _feedForwardHCBase.wrappedValue = MLXArray.zeros([mixingSize], dtype: .float32)
        _attentionHCScale.wrappedValue = MLXArray.zeros([3], dtype: .float32)
        _feedForwardHCScale.wrappedValue = MLXArray.zeros([3], dtype: .float32)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        startPosition: Int,
        inputIDs: MLXArray,
        state: DeepSeekFlashAttentionState,
        imageVisibility: DeepSeekFlashImageVisibility?
    ) -> MLXArray {
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
            state: state,
            imageVisibility: imageVisibility)
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
}


enum DeepSeekFlashHyperConnection {
    static func pre(
        _ x: MLXArray,
        function: MLXArray,
        scale: MLXArray,
        base: MLXArray,
        configuration: DeepSeekFlashConfiguration
    ) -> (hidden: MLXArray, post: MLXArray, combination: MLXArray) {
        let shape = x.shape
        let multiplier = configuration.hyperConnectionMultiplier
        let flat = x.flattened(start: 2).asType(.float32)
        let reciprocalRMS = rsqrt(
            mean(flat * flat, axis: -1, keepDims: true) + configuration.rmsNormEpsilon)
        let mixes = flat.matmul(function.swappedAxes(-1, -2)) * reciprocalRMS
        let pre = MLX.sigmoid(
            mixes[.ellipsis, 0 ..< multiplier] * scale[0]
                + base[0 ..< multiplier])
            + configuration.hyperConnectionEpsilon
        let post = 2 * MLX.sigmoid(
            mixes[.ellipsis, multiplier ..< (2 * multiplier)] * scale[1]
                + base[multiplier ..< (2 * multiplier)])
        var combination = mixes[.ellipsis, (2 * multiplier)...]
            .reshaped(Array(mixes.shape.dropLast()) + [multiplier, multiplier])
        combination = softmax(combination, axis: -1)
            + configuration.hyperConnectionEpsilon
        combination = combination
            / (sum(combination, axis: -2, keepDims: true)
                + configuration.hyperConnectionEpsilon)
        if configuration.hyperConnectionSinkhornIterations > 1 {
            for _ in 1 ..< configuration.hyperConnectionSinkhornIterations {
                combination = combination
                    / (sum(combination, axis: -1, keepDims: true)
                        + configuration.hyperConnectionEpsilon)
                combination = combination
                    / (sum(combination, axis: -2, keepDims: true)
                        + configuration.hyperConnectionEpsilon)
            }
        }
        let hidden = sum(
            pre.expandedDimensions(axis: -1) * flat.reshaped(shape),
            axis: 2)
            .asType(x.dtype)
        return (hidden, post, combination)
    }

    static func post(
        _ x: MLXArray,
        residual: MLXArray,
        post: MLXArray,
        combination: MLXArray
    ) -> MLXArray {
        let mixed = sum(
            combination.expandedDimensions(axis: -1)
                * residual.expandedDimensions(axis: -3),
            axis: -2)
        return (post.expandedDimensions(axis: -1) * x.expandedDimensions(axis: -2) + mixed)
            .asType(x.dtype)
    }

    static func head(
        _ x: MLXArray,
        function: MLXArray,
        scale: MLXArray,
        base: MLXArray,
        configuration: DeepSeekFlashConfiguration
    ) -> MLXArray {
        let shape = x.shape
        let flat = x.flattened(start: 2).asType(.float32)
        let reciprocalRMS = rsqrt(
            mean(flat * flat, axis: -1, keepDims: true) + configuration.rmsNormEpsilon)
        let mixes = flat.matmul(function.swappedAxes(-1, -2)) * reciprocalRMS
        let weights = MLX.sigmoid(mixes * scale + base)
            + configuration.hyperConnectionEpsilon
        return sum(
            weights.expandedDimensions(axis: -1) * flat.reshaped(shape),
            axis: 2)
            .asType(x.dtype)
    }
}
