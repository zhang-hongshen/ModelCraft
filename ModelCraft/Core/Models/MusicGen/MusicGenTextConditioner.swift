//
//  MusicGenTextConditioner.swift
//  ModelCraft
//
//  Created by Hongshen on 23/5/26.
//

import MLX
import MLXNN

// MARK: - Text Conditioner
public class MusicGenTextConditioner: Module {
    @ModuleInfo(key: "_t5") var t5Model: MusicGenT5
    @ModuleInfo(key: "output_proj") var outputProj: Linear
    var tokenizer: MusicGenTokenizer

    init(inputDim: Int, dimKv: Int, dimFf: Int, numHeads: Int, numLayers: Int, numDecoderLayers: Int, hiddenSize: Int, layerNormEpsilon: Float, relativeAttentionNumBuckets: Int, relativeAttentionMaxDistance: Int, decoderStartTokenId: Int, tieWordEmbeddings: Bool, vocabSize: Int, feedForwardProj: String?, t5: MusicGenT5? = nil, tokenizer: MusicGenTokenizer) throws {
        self._t5Model.wrappedValue = t5 ?? MusicGenT5(inputDim: inputDim, dimKv: dimKv, dimFf: dimFf, numHeads: numHeads, numLayers: numLayers, numDecoderLayers: numDecoderLayers, layerNormEpsilon: layerNormEpsilon, relativeAttentionNumBuckets: relativeAttentionNumBuckets, relativeAttentionMaxDistance: relativeAttentionMaxDistance, decoderStartTokenId: decoderStartTokenId, tieWordEmbeddings: tieWordEmbeddings, vocabSize: vocabSize, feedForwardProj: feedForwardProj)
        self._outputProj.wrappedValue = Linear(inputDim, hiddenSize, bias: true)
        self.tokenizer = tokenizer
    }

    func callAsFunction(_ text: String) -> MLXArray {
        let x = tokenizer.encode(text)
        let encoded = t5Model.encode(x)
        return outputProj(encoded)
    }
}
