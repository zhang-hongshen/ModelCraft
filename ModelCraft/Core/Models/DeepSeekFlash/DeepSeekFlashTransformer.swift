//
//  DeepSeekFlashTransformer.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import Foundation
import MLX
import MLXNN

final class DeepSeekFlashEmbedding: Module {
    let vocabularySize: Int
    @ParameterInfo(key: "weight") var weight: MLXArray

    init(vocabularySize: Int, dimensions: Int) {
        self.vocabularySize = vocabularySize
        _weight.wrappedValue = MLXArray.zeros(
            [vocabularySize, dimensions], dtype: .bfloat16)
        super.init()
    }

    func callAsFunction(_ inputIDs: MLXArray) -> MLXArray {
        let ids = inputIDs.asType(.int32)
        let imageMask = ids .>= Int32(vocabularySize)
        let safeIDs = MLX.where(imageMask, MLXArray(Int32(0)), ids)
        return MLX.where(
            imageMask.expandedDimensions(axis: -1),
            MLXArray.zeros([1], dtype: weight.dtype),
            weight.take(safeIDs, axis: 0))
    }
}

final class DeepSeekFlashHead: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray

    init(vocabularySize: Int, dimensions: Int) {
        _weight.wrappedValue = MLXArray.zeros(
            [vocabularySize, dimensions], dtype: .bfloat16)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, fullLogits: Bool = false) -> MLXArray {
        let hidden = fullLogits ? x : x[0..., -1]
        return hidden.asType(.float32).matmul(weight.asType(.float32).swappedAxes(-1, -2))
    }
}

struct DeepSeekFlashForwardOutput {
    /// `[batch, positions, vocabulary]`: every input position when requested, otherwise the last.
    let logits: MLXArray
    /// The DSpark target layers' hidden states for the last `min(positions, slidingWindow)` positions.
    let dsparkHidden: MLXArray
}

final class DeepSeekFlashTransformer: Module {
    /// Inputs up to this length run as one graph; longer ones are evaluated layer by layer to
    /// bound their memory.
    private static let singleGraphLength = 16

    let configuration: DeepSeekFlashConfiguration
    let maximumSequenceLength: Int

    @ModuleInfo(key: "embed") var embedding: DeepSeekFlashEmbedding
    @ModuleInfo(key: "aligner") var aligner: DeepSeekFlashVisionAligner
    @ModuleInfo(key: "layers") var layers: [DeepSeekFlashTransformerBlock]
    @ModuleInfo(key: "norm") var norm: DeepSeekFlashRMSNorm
    @ModuleInfo(key: "head") var head: DeepSeekFlashHead
    @ModuleInfo(key: "mtp") var mtp: [DeepSeekFlashDSparkBlock]
    @ModuleInfo(key: "vision") var vision: DeepSeekFlashVisionEncoder

    @ParameterInfo(key: "image_end") var imageEnd: MLXArray
    @ParameterInfo(key: "image_newline") var imageNewline: MLXArray
    @ParameterInfo(key: "image_pad") var imagePad: MLXArray
    @ParameterInfo(key: "image_start") var imageStart: MLXArray
    @ParameterInfo(key: "hc_head_base") var headHCBase: MLXArray
    @ParameterInfo(key: "hc_head_fn") var headHCFunction: MLXArray
    @ParameterInfo(key: "hc_head_scale") var headHCScale: MLXArray

    /// With `streamsExperts`, the routed experts are not part of the module; the loader gives
    /// each MoE block an expert source instead.
    init(
        configuration: DeepSeekFlashConfiguration,
        maximumSequenceLength: Int,
        streamsExperts: Bool
    ) {
        self.configuration = configuration
        self.maximumSequenceLength = min(
            maximumSequenceLength, configuration.maxPositionEmbeddings)
        _embedding.wrappedValue = DeepSeekFlashEmbedding(
            vocabularySize: configuration.vocabularySize,
            dimensions: configuration.hiddenSize)
        _layers.wrappedValue = (0 ..< configuration.numHiddenLayers).map {
            DeepSeekFlashTransformerBlock(
                layerID: $0, configuration: configuration, streamsExperts: streamsExperts)
        }
        _norm.wrappedValue = DeepSeekFlashRMSNorm(
            dimensions: configuration.hiddenSize,
            epsilon: configuration.rmsNormEpsilon)
        _head.wrappedValue = DeepSeekFlashHead(
            vocabularySize: configuration.vocabularySize,
            dimensions: configuration.hiddenSize)
        _mtp.wrappedValue = (0 ..< configuration.numNextPredictLayers).map { stageID in
            DeepSeekFlashDSparkBlock(
                stageID: stageID, configuration: configuration, streamsExperts: streamsExperts)
        }
        _vision.wrappedValue = DeepSeekFlashVisionEncoder(configuration: configuration)
        _aligner.wrappedValue = DeepSeekFlashVisionAligner(configuration: configuration)
        let multiplier = configuration.hyperConnectionMultiplier
        _headHCFunction.wrappedValue = MLXArray.zeros(
            [multiplier, multiplier * configuration.hiddenSize], dtype: .float32)
        _headHCBase.wrappedValue = MLXArray.zeros([multiplier], dtype: .float32)
        _headHCScale.wrappedValue = MLXArray.zeros([1], dtype: .float32)
        _imageStart.wrappedValue = MLXArray.zeros(
            [configuration.hiddenSize], dtype: .bfloat16)
        _imageEnd.wrappedValue = MLXArray.zeros(
            [configuration.hiddenSize], dtype: .bfloat16)
        _imageNewline.wrappedValue = MLXArray.zeros(
            [configuration.hiddenSize], dtype: .bfloat16)
        _imagePad.wrappedValue = MLXArray.zeros(
            [configuration.hiddenSize], dtype: .bfloat16)
        super.init()
        mtp.first?.embedding = embedding
        mtp.last?.head = head
    }

    /// Runs `inputIDs`, the tokens at `startPosition...`, against `cache`. Each layer commits the
    /// tokens as it finishes, so a long input never holds every layer's staged values at once;
    /// with `keepsStaged` they stay staged until the caller commits the accepted part.
    func callAsFunction(
        _ inputIDs: MLXArray,
        images: [DeepSeekFlashImageInput] = [],
        startPosition: Int,
        cache: DeepSeekFlashCache,
        allLogits: Bool = false,
        keepsStaged: Bool = false
    ) throws -> DeepSeekFlashForwardOutput {
        let sequenceLength = inputIDs.dim(1)
        precondition(
            startPosition + sequenceLength <= cache.maximumSequenceLength,
            "DeepSeekFlash sequence exceeds the configured cache length")
        precondition(images.isEmpty || startPosition == 0, "Images are placed from the first token")

        // A long input routes to nearly every expert, so prefetching it would only hold them all at once.
        if sequenceLength <= Self.singleGraphLength {
            for block in layers.prefix(configuration.numHashLayers) {
                try block.feedForward.prefetch(inputIDs: inputIDs)
            }
        }

        var tokenEmbeddings = embedding(inputIDs)
        let imageVisibility: DeepSeekFlashImageVisibility?
        if !images.isEmpty {
            tokenEmbeddings = try mergeImageEmbeddings(images, into: tokenEmbeddings)
            imageVisibility = makeImageVisibility(inputIDs)
        } else {
            imageVisibility = nil
        }
        var hidden = tokenEmbeddings.expandedDimensions(axis: 2)
        hidden = MLX.repeated(
            hidden, count: configuration.hyperConnectionMultiplier, axis: 2)

        let dsparkStart = max(0, sequenceLength - configuration.slidingWindow)
        var dsparkHidden = [MLXArray]()
        for (layerID, block) in layers.enumerated() {
            let state = cache.states[layerID]
            hidden = try block(
                hidden,
                startPosition: startPosition,
                inputIDs: inputIDs,
                state: state,
                imageVisibility: imageVisibility)
            if configuration.dsparkTargetLayerIDs.contains(layerID) {
                dsparkHidden.append(mean(hidden[0..., dsparkStart...], axis: 2))
            }
            if !keepsStaged {
                state.commit(count: sequenceLength)
            }
            if sequenceLength > Self.singleGraphLength {
                eval([hidden] + dsparkHidden + state.arrays)
            }
        }

        var collapsed = DeepSeekFlashHyperConnection.head(
            hidden,
            function: headHCFunction,
            scale: headHCScale,
            base: headHCBase,
            configuration: configuration)
        if !allLogits {
            collapsed = collapsed[0..., (sequenceLength - 1)...]
        }
        return DeepSeekFlashForwardOutput(
            logits: head(norm(collapsed), fullLogits: true),
            dsparkHidden: MLX.concatenated(dsparkHidden, axis: -1))
    }

    private func mergeImageEmbeddings(
        _ images: [DeepSeekFlashImageInput],
        into embeddings: MLXArray
    ) throws -> MLXArray {
        var result = embeddings
        let special = MLX.stacked(
            [imageStart, imagePad, imagePad, imageNewline, imageEnd], axis: 0)

        for image in images {
            var block = special.take(MLXArray(image.types.map(Int32.init)), axis: 0)
            let visionEmbedding = vision(
                image.patches,
                height: image.visionHeight,
                width: image.visionWidth)
            let encoded = aligner(
                visionEmbedding,
                height: image.visionHeight,
                width: image.visionWidth)
                .take(MLXArray(image.permutation.map(Int32.init)), axis: 0)
            eval(encoded)
            var encodedIndex = 0
            for (index, type) in image.types.enumerated() where type == 2 {
                block[index] = encoded[encodedIndex]
                encodedIndex += 1
            }
            result[0, image.start ..< (image.start + image.types.count)] = block
        }
        eval(result)
        return result
    }

    private func makeImageVisibility(_ inputIDs: MLXArray) -> DeepSeekFlashImageVisibility {
        eval(inputIDs)
        let ids = inputIDs.asArray(Int32.self)
        let startID = Int32(configuration.vocabularySize)
        let endID = Int32(configuration.vocabularySize + 4)
        var left = Array(repeating: 0, count: ids.count)
        var right = Array(repeating: 0, count: ids.count)
        var imageStartIndex: Int?
        for (index, id) in ids.enumerated() {
            if id == startID {
                imageStartIndex = index
            }
            if let start = imageStartIndex {
                left[index] = min(
                    index - start,
                    configuration.visionMaximumTokenCount - 1)
                if id == endID {
                    for position in start ... index {
                        right[position] = min(
                            index - position,
                            configuration.visionMaximumTokenCount)
                    }
                    imageStartIndex = nil
                }
            }
        }
        return DeepSeekFlashImageVisibility(left: left, right: right)
    }
}

enum DeepSeekFlashSampler {
    static func sample(logits: MLXArray, temperature: Float) -> MLXArray {
        if temperature == 0 {
            return argMax(logits, axis: -1).asType(.int32)
        }
        return MLXRandom.categorical(logits / max(temperature, 1e-5), axis: -1)
            .asType(.int32)
    }
}
