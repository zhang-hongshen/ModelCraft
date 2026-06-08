//
//  MusicGenLoader.swift
//  ModelCraft
//
//  Created by Hongshen on 23/5/26.
//

import Foundation
import Hub
import MLX


public class MusicGenLoader {

    private static func loadWeights(
        from url: URL
    ) throws -> [String: MLXArray] {
        return try MLX.loadArrays(url: url)
    }
    
    public static func loadT5(hub: HubApi = .default, configuration: MusicGenConfiguration) throws -> MusicGenT5 {
        let directory = hub.localRepoLocation(Hub.Repo(id: configuration.textEncoderParameters.id))
        let url = directory.appending(component: "model.safetensors")
        
        let model = MusicGenT5(
            inputDim: configuration.textEncoderParameters.dim, dimKv: configuration.textEncoderParameters.dimKv, dimFf: configuration.textEncoderParameters.dimFf,
            numHeads: configuration.textEncoderParameters.numHeads, numLayers: configuration.textEncoderParameters.numLayers, numDecoderLayers: configuration.textEncoderParameters.numDecoderLayers, layerNormEpsilon: configuration.textEncoderParameters.layerNormEpsilon,
            relativeAttentionNumBuckets: configuration.textEncoderParameters.relativeAttentionNumBuckets, relativeAttentionMaxDistance: configuration.textEncoderParameters.relativeAttentionMaxDistance,
            decoderStartTokenId: configuration.textEncoderParameters.decoderStartTokenId, tieWordEmbeddings: configuration.textEncoderParameters.tieWordEmbeddings, vocabSize: configuration.textEncoderParameters.vocabSize, feedForwardProj: configuration.textEncoderParameters.feedForwardProj)
        
        let weights = MusicGenT5.sanitize(try loadWeights(from: url)).mapValues { $0.asType(.bfloat16) }.map { ($0.key, $0.value) }
        
        model.update(parameters: .unflattened(weights))
        return model
    }
    
    public static func loadAudioEncoder(hub: HubApi = .default, configuration: MusicGenConfiguration) throws -> MusicGenAudioDecoder {
        let directory = hub.localRepoLocation(Hub.Repo(id: configuration.audioEncoderParameters.id))
        let url = directory.appending(component: "model.safetensors")
        let model = MusicGenAudioDecoder(config: configuration.audioEncoderParameters)
        let weights = try loadWeights(from: url).map { ($0.key, $0.value) }
        model.update(parameters: .unflattened(weights))
        return model
    }
    
    public static func loadTokenizer(hub: HubApi = .default, configuration: MusicGenConfiguration) throws -> MusicGenTokenizer {
        let directory = hub.localRepoLocation(Hub.Repo(id: configuration.id))
        let tokenizerDataURL = directory.appending(component: "tokenizer.json")
        let tokenizerConfigURL = directory.appending(component: "tokenizer_config.json")
        let tokenizerData = try hub.configuration(fileURL: tokenizerDataURL)
        let tokenizerConfig = try hub.configuration(fileURL: tokenizerConfigURL)
        return try MusicGenTokenizer(decoderStartTokenId: configuration.textEncoderParameters.decoderStartTokenId, tokenizerData: tokenizerData, tokenizerConfig: tokenizerConfig)
    }
    
    public static func loadTextConditioner(hub: HubApi = .default, configuration: MusicGenConfiguration) throws -> MusicGenTextConditioner {
        let t5 = try MusicGenLoader.loadT5(hub: hub, configuration: configuration)
        let tokenizer = try loadTokenizer(hub: hub, configuration: configuration)
        return try MusicGenTextConditioner(
            inputDim: configuration.textEncoderParameters.dim, dimKv: configuration.textEncoderParameters.dimKv, dimFf: configuration.textEncoderParameters.dimFf,
            numHeads: configuration.textEncoderParameters.numHeads, numLayers: configuration.textEncoderParameters.numLayers, numDecoderLayers: configuration.textEncoderParameters.numDecoderLayers,
            hiddenSize: configuration.decoderParameters.hiddenSize, layerNormEpsilon: configuration.textEncoderParameters.layerNormEpsilon,
            relativeAttentionNumBuckets: configuration.textEncoderParameters.relativeAttentionNumBuckets, relativeAttentionMaxDistance: configuration.textEncoderParameters.relativeAttentionMaxDistance,
            decoderStartTokenId: configuration.textEncoderParameters.decoderStartTokenId, tieWordEmbeddings: configuration.textEncoderParameters.tieWordEmbeddings, vocabSize: configuration.textEncoderParameters.vocabSize, feedForwardProj: configuration.textEncoderParameters.feedForwardProj, t5: t5, tokenizer: tokenizer)
    }
    
}
