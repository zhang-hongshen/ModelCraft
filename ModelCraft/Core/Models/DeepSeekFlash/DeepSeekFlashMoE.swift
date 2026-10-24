//
//  DeepSeekFlashMoE.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import MLX
import MLXNN

final class DeepSeekFlashMoE: Module {
    /// Experts per batch when routed experts are read from disk, which bounds the stacked copy.
    private static let streamedChunkSize = 32

    let layerID: Int
    let configuration: DeepSeekFlashConfiguration

    @ModuleInfo(key: "gate") var gate: DeepSeekFlashGate
    /// The routed experts when they are resident; `nil` when they are read through `expertSource`.
    @ModuleInfo(key: "experts") var experts: DeepSeekFlashSwitchGLU?
    @ModuleInfo(key: "shared_experts") var sharedExpert: DeepSeekFlashExpert
    var expertSource: DeepSeekFlashExpertSource?

    init(layerID: Int, configuration: DeepSeekFlashConfiguration, streamsExperts: Bool) {
        self.layerID = layerID
        self.configuration = configuration
        _gate.wrappedValue = DeepSeekFlashGate(layerID: layerID, configuration: configuration)
        _experts.wrappedValue = streamsExperts
            ? nil : DeepSeekFlashSwitchGLU(configuration: configuration)
        _sharedExpert.wrappedValue = DeepSeekFlashExpert(
            configuration: configuration, storage: .mxfp8Block128)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        inputIDs: MLXArray
    ) throws -> MLXArray {
        let shape = x.shape
        let flat = x.reshaped([-1, configuration.hiddenSize])
        let routing = gate(flat, inputIDs: inputIDs)
        let routed: MLXArray
        if let experts {
            routed = experts(flat, indices: routing.indices, weights: routing.weights)
        } else {
            routed = try streamedExperts(flat, routing: routing, source: expertSource!)
        }
        let output = routed + sharedExpert(flat).asType(.float32)
        return output.asType(x.dtype).reshaped(shape)
    }

    /// Starts reading the experts that hash routing assigns to `inputIDs`, so the reads overlap
    /// the layers before this one.
    func prefetch(inputIDs: MLXArray) throws {
        guard let expertSource, let tokenToExpert = gate.tokenToExpert else { return }
        let tokenIDs = inputIDs.flattened().asType(.int32)
        let textIDs = MLX.where(
            tokenIDs .>= Int32(configuration.vocabularySize), MLXArray(Int32(0)), tokenIDs)
        let assigned = tokenToExpert.take(textIDs, axis: 0).asType(.int32)
        eval(assigned)
        _ = try expertSource.cache.experts(
            Set(assigned.asArray(Int32.self).map(Int.init)).sorted(),
            from: expertSource)
    }

    /// Runs the routed experts read through the cache, a chunk of experts at a time.
    private func streamedExperts(
        _ flat: MLXArray,
        routing: (weights: MLXArray, indices: MLXArray),
        source: DeepSeekFlashExpertSource
    ) throws -> MLXArray {
        eval(routing.indices)
        let assignments = routing.indices.asArray(Int32.self).map(Int.init)
        let routingWeights = routing.weights.flattened()
        let expertIDs = Set(assignments).sorted()
        var output = MLXArray.zeros(like: flat).asType(.float32)

        for start in stride(from: 0, to: expertIDs.count, by: Self.streamedChunkSize) {
            let chunk = Array(expertIDs[start ..< min(start + Self.streamedChunkSize, expertIDs.count)])
            let experts = try DeepSeekFlashSwitchGLU(
                configuration: configuration,
                stacking: source.cache.experts(chunk, from: source))
            let localIndex = Dictionary(uniqueKeysWithValues: chunk.enumerated().map { ($1, $0) })
            var rows = [Int32]()
            var slots = [Int32]()
            var locals = [Int32]()
            for (slot, expertID) in assignments.enumerated() {
                guard let local = localIndex[expertID] else { continue }
                rows.append(Int32(slot / configuration.numExpertsPerToken))
                slots.append(Int32(slot))
                locals.append(Int32(local))
            }
            let rowIndices = MLXArray(rows)
            let contribution = experts(
                flat.take(rowIndices, axis: 0),
                indices: MLXArray(locals).reshaped([-1, 1]),
                weights: routingWeights.take(MLXArray(slots), axis: 0).reshaped([-1, 1]))
            output = output.at[rowIndices].add(contribution)
            eval(output)
        }
        return output
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

/// One projection of every routed expert, stacked along the first axis and stored as MXFP4.
final class DeepSeekFlashSwitchLinear: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    @ParameterInfo(key: "scale") var scale: MLXArray

    init(expertCount: Int, inputDimensions: Int, outputDimensions: Int) {
        _weight.wrappedValue = MLXArray.zeros(
            [expertCount, outputDimensions, inputDimensions / 8], dtype: .uint32)
        _scale.wrappedValue = MLXArray.zeros(
            [expertCount, outputDimensions, inputDimensions / 32], dtype: .uint8)
        super.init()
    }

    init(weight: MLXArray, scale: MLXArray) {
        _weight.wrappedValue = weight
        _scale.wrappedValue = scale
        super.init()
    }

    func callAsFunction(_ x: MLXArray, _ indices: MLXArray, sortedIndices: Bool) -> MLXArray {
        gatherQuantizedMM(
            x, weight,
            scales: scale, biases: nil,
            rhsIndices: indices,
            transpose: true, groupSize: 32, bits: 4, mode: .mxfp4,
            sortedIndices: sortedIndices)
    }
}

/// The routed experts as one gathered SwiGLU, so a step runs three kernels instead of a pass per expert.
final class DeepSeekFlashSwitchGLU: Module {
    let configuration: DeepSeekFlashConfiguration
    @ModuleInfo(key: "w1") var gateProjection: DeepSeekFlashSwitchLinear
    @ModuleInfo(key: "w2") var downProjection: DeepSeekFlashSwitchLinear
    @ModuleInfo(key: "w3") var upProjection: DeepSeekFlashSwitchLinear

    init(configuration: DeepSeekFlashConfiguration) {
        self.configuration = configuration
        let expertCount = configuration.numRoutedExperts
        _gateProjection.wrappedValue = DeepSeekFlashSwitchLinear(
            expertCount: expertCount,
            inputDimensions: configuration.hiddenSize,
            outputDimensions: configuration.moeIntermediateSize)
        _downProjection.wrappedValue = DeepSeekFlashSwitchLinear(
            expertCount: expertCount,
            inputDimensions: configuration.moeIntermediateSize,
            outputDimensions: configuration.hiddenSize)
        _upProjection.wrappedValue = DeepSeekFlashSwitchLinear(
            expertCount: expertCount,
            inputDimensions: configuration.hiddenSize,
            outputDimensions: configuration.moeIntermediateSize)
        super.init()
    }

    /// Stacks single experts' weights, given in `DeepSeekFlashExpertCache.tensorNames` order.
    init(configuration: DeepSeekFlashConfiguration, stacking experts: [[MLXArray]]) {
        self.configuration = configuration
        func stacked(_ index: Int) -> MLXArray {
            MLX.stacked(experts.map { $0[index] }, axis: 0)
        }
        _gateProjection.wrappedValue = DeepSeekFlashSwitchLinear(
            weight: stacked(0), scale: stacked(1))
        _downProjection.wrappedValue = DeepSeekFlashSwitchLinear(
            weight: stacked(2), scale: stacked(3))
        _upProjection.wrappedValue = DeepSeekFlashSwitchLinear(
            weight: stacked(4), scale: stacked(5))
        super.init()
    }

    /// Sums each row's experts, scaled by their routing weights, in float32.
    /// `indices` and `weights` are `[rows, experts per row]`.
    func callAsFunction(_ x: MLXArray, indices: MLXArray, weights: MLXArray) -> MLXArray {
        let inputType = x.dtype
        let rowCount = indices.dim(0)
        let slotCount = indices.dim(1)
        let sortedIndices = indices.size >= 64
        var input = x.expandedDimensions(axes: [-2, -3])
        var expertIndices = indices
        var routingWeights = weights.reshaped([rowCount, slotCount, 1, 1])
        var inverseOrder: MLXArray?
        if sortedIndices {
            // Grouping rows by expert lets the gathered kernels read each expert once.
            let flatIndices = indices.flattened()
            let order = argSort(flatIndices)
            inverseOrder = argSort(order)
            input = input.flattened(start: 0, end: -3)[order.floorDivide(slotCount)]
            expertIndices = flatIndices[order]
            routingWeights = weights.flattened()[order].reshaped([-1, 1, 1])
        }

        var gate = gateProjection(input, expertIndices, sortedIndices: sortedIndices)
            .asType(.float32)
        var up = upProjection(input, expertIndices, sortedIndices: sortedIndices)
            .asType(.float32)
        if configuration.swigluLimit > 0 {
            up = MLX.clip(
                up,
                min: -configuration.swigluLimit,
                max: configuration.swigluLimit)
            gate = MLX.minimum(gate, configuration.swigluLimit)
        }
        let hidden = DeepSeekFlashExpert.swiGLU(gate, up) * routingWeights
        var output = downProjection(
            hidden.asType(inputType), expertIndices, sortedIndices: sortedIndices)
        if let inverseOrder {
            output = output[inverseOrder].reshaped([rowCount, slotCount, 1, -1])
        }
        return sum(output.squeezed(axis: -2).asType(.float32), axis: -2)
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

    func callAsFunction(_ x: MLXArray) -> MLXArray {
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
        return downProjection(Self.swiGLU(gate, up).asType(inputType))
    }

    /// `silu(gate) * up` as one kernel.
    static let swiGLU = compile(shapeless: true) { gate, up in
        gate * MLX.sigmoid(gate) * up
    }
}
