//
//  DeepSeekFlashMoE.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import MLX
import MLXNN


final class DeepSeekFlashMoE: Module {
    let layerID: Int
    let configuration: DeepSeekFlashConfiguration

    @ModuleInfo(key: "gate") var gate: DeepSeekFlashGate
    @ModuleInfo(key: "experts") var experts: [DeepSeekFlashExpert]
    @ModuleInfo(key: "shared_experts") var sharedExpert: DeepSeekFlashExpert

    init(layerID: Int, configuration: DeepSeekFlashConfiguration) {
        self.layerID = layerID
        self.configuration = configuration
        _gate.wrappedValue = DeepSeekFlashGate(layerID: layerID, configuration: configuration)
        _experts.wrappedValue = (0 ..< configuration.numRoutedExperts).map { _ in
            DeepSeekFlashExpert(configuration: configuration, storage: .mxfp4Group32)
        }
        _sharedExpert.wrappedValue = DeepSeekFlashExpert(
            configuration: configuration, storage: .mxfp8Block128)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        inputIDs: MLXArray
    ) -> MLXArray {
        let shape = x.shape
        let flat = x.reshaped([-1, configuration.hiddenSize])
        let routing = gate(flat, inputIDs: inputIDs)
        eval(routing.indices)
        let expertIndices = routing.indices.asArray(Int32.self)
        var output = MLXArray.zeros(like: flat).asType(.float32)

        for expertID in Set(expertIndices).sorted() {
            var rows = [Int32]()
            var slots = [Int32]()
            for (flatIndex, routedExpert) in expertIndices.enumerated()
                where routedExpert == expertID
            {
                rows.append(Int32(flatIndex / configuration.numExpertsPerToken))
                slots.append(Int32(flatIndex))
            }
            let rowIndices = MLXArray(rows)
            let selectedWeights = routing.weights.flattened()
                .take(MLXArray(slots), axis: 0)
                .expandedDimensions(axis: -1)
            let expert = experts[Int(expertID)]
            let contribution = expert(flat.take(rowIndices, axis: 0), weights: selectedWeights)
                .asType(.float32)
            output = output.at[rowIndices].add(contribution)
            eval(output)
        }

        output = output + sharedExpert(flat).asType(.float32)
        return output.asType(x.dtype).reshaped(shape)
    }
}


final class DeepSeekFlashGate: Module {
    let layerID: Int
    let configuration: DeepSeekFlashConfiguration

    @ParameterInfo(key: "weight") var weight: MLXArray
    @ParameterInfo(key: "bias") var bias: MLXArray?
    @ParameterInfo(key: "bias_vl") var visionBias: MLXArray
    @ParameterInfo(key: "tid2eid") var tokenToExpert: MLXArray?

    init(layerID: Int, configuration: DeepSeekFlashConfiguration) {
        self.layerID = layerID
        self.configuration = configuration
        _weight.wrappedValue = MLXArray.zeros(
            [configuration.numRoutedExperts, configuration.hiddenSize], dtype: .bfloat16)
        _bias.wrappedValue = MLXArray.zeros(
            [configuration.numRoutedExperts], dtype: .float32)
        _visionBias.wrappedValue = MLXArray.zeros(
            [configuration.numRoutedExperts], dtype: .float32)
        if layerID < configuration.numHashLayers {
            _tokenToExpert.wrappedValue = MLXArray.zeros(
                [configuration.vocabularySize, configuration.numExpertsPerToken], dtype: .int64)
        } else {
            _tokenToExpert.wrappedValue = nil
        }
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        inputIDs: MLXArray
    ) -> (weights: MLXArray, indices: MLXArray) {
        var scores = x.asType(.float32).matmul(weight.asType(.float32).swappedAxes(-1, -2))
        scores = MLX.sqrt(MLXNN.softplus(scores))
        let originalScores = scores
        let tokenIDs = inputIDs.flattened().asType(.int32)
        let imageMask = tokenIDs .>= Int32(configuration.vocabularySize)
        let indices: MLXArray
        if let tokenToExpert {
            let safeTokenIDs = MLX.where(imageMask, MLXArray(Int32(0)), tokenIDs)
            let textIndices = tokenToExpert.take(safeTokenIDs, axis: 0).asType(.int32)
            let first = configuration.numRoutedExperts - configuration.numExpertsPerToken
            let visionIndices = argPartition(
                scores + visionBias, kth: first, axis: -1)[0..., first...]
                .asType(.int32)
            indices = MLX.where(
                imageMask.expandedDimensions(axis: -1), visionIndices, textIndices)
        } else {
            let selectedBias = MLX.where(
                imageMask.expandedDimensions(axis: -1), visionBias, bias!)
            scores = scores + selectedBias
            let first = configuration.numRoutedExperts - configuration.numExpertsPerToken
            indices = argPartition(scores, kth: first, axis: -1)[0..., first...]
                .asType(.int32)
        }
        var routingWeights = takeAlong(originalScores, indices, axis: -1)
        routingWeights = routingWeights
            / sum(routingWeights, axis: -1, keepDims: true)
            * configuration.routedScalingFactor
        return (routingWeights, indices)
    }
}

final class DeepSeekFlashExpert: Module {
    let configuration: DeepSeekFlashConfiguration
    @ModuleInfo(key: "w1") var gateProjection: DeepSeekFlashLinear
    @ModuleInfo(key: "w2") var downProjection: DeepSeekFlashLinear
    @ModuleInfo(key: "w3") var upProjection: DeepSeekFlashLinear

    init(
        configuration: DeepSeekFlashConfiguration,
        storage: DeepSeekFlashLinearStorage
    ) {
        self.configuration = configuration
        _gateProjection.wrappedValue = DeepSeekFlashLinear(
            configuration.hiddenSize, configuration.moeIntermediateSize, storage: storage)
        _downProjection.wrappedValue = DeepSeekFlashLinear(
            configuration.moeIntermediateSize, configuration.hiddenSize, storage: storage)
        _upProjection.wrappedValue = DeepSeekFlashLinear(
            configuration.hiddenSize, configuration.moeIntermediateSize, storage: storage)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, weights: MLXArray? = nil) -> MLXArray {
        let inputType = x.dtype
        var gate = gateProjection(x).asType(.float32)
        var up = upProjection(x).asType(.float32)
        if configuration.swigluLimit > 0 {
            up = MLX.clip(
                up,
                min: -configuration.swigluLimit,
                max: configuration.swigluLimit)
            gate = MLX.minimum(gate, configuration.swigluLimit)
        }
        var hidden = Self.swiGLU(gate, up)
        if let weights {
            hidden = hidden * weights
        }
        return downProjection(hidden.asType(inputType))
    }

    /// `silu(gate) * up` as one kernel.
    private static let swiGLU = compile(shapeless: true) { gate, up in
        gate * MLX.sigmoid(gate) * up
    }
}
