// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXNN
import MLXFast
import Hub


public class MusicGen: Module {
    
    let textConditioner: MusicGenTextConditioner
    var audioDecoder: MusicGenAudioDecoder
    let decoder: MusicGenTransformerDecoder
    
    let configuration: MusicGenConfiguration
    
    public init(configuration: MusicGenConfiguration, textConditioner: MusicGenTextConditioner? = nil,
                audioDecoder: MusicGenAudioDecoder? = nil) throws {
        self.configuration = configuration
        
        self.textConditioner = try textConditioner ??  MusicGenLoader.loadTextConditioner(configuration: configuration)
        
        
        
        self.decoder = MusicGenTransformerDecoder(numCodebooks: configuration.decoderParameters.numCodebooks,
                                               numAttentionHeads: configuration.decoderParameters.numAttentionHeads,
                                               numHiddenLayers: configuration.decoderParameters.numHiddenLayers,
                                               codebookSize: configuration.audioEncoderParameters.codebookSize,
                                               hiddenSize: configuration.decoderParameters.hiddenSize,
                                               dimFFN: configuration.decoderParameters.ffnDim)
        self.audioDecoder = MusicGenAudioDecoder(config: configuration.audioEncoderParameters)
        
        super.init()
    }
    
    public func ensureLoaded() throws {
        eval(textConditioner, audioDecoder)
    }
    
    
    func topKSampling(
        logits: MLXArray, topK: Int, temperature: Float, axis: Int = -1
    ) -> MLXArray {
        let probs = MLX.softmax(logits * (1.0 / temperature), axis: axis)
        let sortedIndices = MLX.argSort(probs, axis: axis)
        let sortedProbs = MLX.takeAlong(probs, sortedIndices, axis: axis)
        let probThreshold = MLX.take(sortedProbs, MLXArray([-topK]), axis: axis)
        
        let topProbs = MLX.where(
            sortedProbs .> probThreshold,
            sortedProbs,
            MLX.zeros(sortedProbs.shape)
        )
        
        let sortedToken = MLXRandom.categorical(MLX.log(topProbs), axis: axis)
        let token = MLX.takeAlong(
            sortedIndices,
            sortedToken.expandedDimensions(axes: [axis]),
            axis: axis
        )
        
        return token
    }
    
    public func generate(_ req: MusicGenEvaluateParameters) -> MLXArray {
        let bosTokenId = configuration.decoderParameters.bosTokenId
        let numCodebooks = configuration.decoderParameters.numCodebooks
        
        let audioShape = [1, req.maxSteps + 1, numCodebooks]
        var audioSeq = MLX.full(audioShape, values: Int32(bosTokenId))
        
        let textTokens = textConditioner(req.prompt)
        
        let unconditioned = MLX.zeros(textTokens.shape)
        let batchedConditioning = MLX.concatenated([textTokens, unconditioned], axis: 0)
        
        let headDim = configuration.decoderParameters.hiddenSize / configuration.decoderParameters.numAttentionHeads
        
        var cache: [MusicGenKVCache?] = (0..<configuration.decoderParameters.numHiddenLayers).map { _ in
            MusicGenKVCache(headDim: headDim, nKvHeads: configuration.decoderParameters.numAttentionHeads)
        }
        
        for offset in 0..<req.maxSteps {
            let audioInput = MLX.broadcast(audioSeq[0..., offset..<offset+1], to: [2, 1, 1])
            
            let audioLogits = decoder(audioTokens: audioInput, conditioning: batchedConditioning, cache: &cache)
            let condLogits = audioLogits[0...0]
            let uncondLogits = audioLogits[1...1]
            
            let guidedLogits = uncondLogits + (condLogits - uncondLogits) * req.guidanceCoef
            var audioTokens = topKSampling(logits: guidedLogits, topK: req.topK, temperature: req.temperature, axis: -2)
            
            if offset + 1 < req.maxSteps {
                audioTokens[0..., (offset + 1)..., 0...] = MLXArray(Int32(bosTokenId))
            }
            let historyLimit = -req.maxSteps + offset
            if historyLimit < 0 {
                audioTokens[0..., ..<historyLimit, 0...] = MLXArray(Int32(bosTokenId))
            }
            
            audioSeq[0..., (offset + 1)...(offset + 1), 0...] = audioTokens
            MLX.eval(audioSeq)
        }
        
        for i in 0..<numCodebooks {
            let srcRange = i..<(req.maxSteps + 1 - numCodebooks + i)
            let dstRange = 0..<(req.maxSteps + 1 - numCodebooks)
            audioSeq[0..., dstRange, i...i] = audioSeq[0..., srcRange, i...i]
        }
        audioSeq = audioSeq[0..., 1..<(req.maxSteps + 1 - numCodebooks + 1), 0...]
        audioSeq = audioSeq.swappedAxes(-1, -2).expandedDimensions(axes: [1])
        
        let audio = audioDecoder.decode(audioCodes: audioSeq, audioScales: [nil])
        return audio[0]
    }
    
    public static func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var outWeights = [String: MLXArray]()
        
        for (key, arr) in weights {
            var k = key
            if k.hasPrefix("transformer.") {
                k = String(k.dropFirst("transformer.".count))
            }
            
            k = k.replacingOccurrences(of: "cross_attention", with: "cross_attn")
            k = k.replacingOccurrences(of: "condition_provider.conditioners.description", with: "text_conditioner")
            
            if k.contains("in_proj_weight") {
                let dim = arr.shape[0] / 3
                let qProjKey = k.replacingOccurrences(of: "in_proj_weight", with: "q_proj.weight")
                let kProjKey = k.replacingOccurrences(of: "in_proj_weight", with: "k_proj.weight")
                let vProjKey = k.replacingOccurrences(of: "in_proj_weight", with: "v_proj.weight")
                
                outWeights[qProjKey] = arr[0..<dim]
                outWeights[kProjKey] = arr[dim..<(dim * 2)]
                outWeights[vProjKey] = arr[(dim * 2)..<(dim * 3)]
                continue
            }
            
            outWeights[k] = arr
        }
        return outWeights
    }
}


public class MusicGenTransformerDecoder: Module {
    let emb: [Embedding]
    let layers: [MusicGenTransformerDecoderLayer]
    let outNorm: LayerNorm
    let linears: [Linear]
    
    let numCodebooks: Int
    let hiddenSize: Int
    
    public init(numCodebooks: Int, numAttentionHeads: Int, numHiddenLayers: Int, codebookSize: Int, hiddenSize: Int, dimFFN: Int) {
        self.numCodebooks = numCodebooks
        self.hiddenSize = hiddenSize
        self.emb = (0..<numCodebooks).map { _ in
            Embedding(embeddingCount: codebookSize + 1, dimensions: hiddenSize)
        }
        self.layers = (0..<numHiddenLayers).map { _ in
            MusicGenTransformerDecoderLayer(numAttentionHeads: numAttentionHeads, hiddenSize: hiddenSize, dimFFN: dimFFN)
        }
        self.outNorm = LayerNorm(dimensions: hiddenSize, eps: 1e-5)
        self.linears = (0..<numCodebooks).map { _ in
            Linear(hiddenSize, codebookSize, bias: false)
        }
    }
    
    private func createSinEmbedding(positions: MLXArray, dim: Int, maxPeriod: Float = 10000.0) -> MLXArray {
        precondition(dim % 2 == 0)
        let halfDim = Int(dim / 2)
        let adim = MLX.arange(0, halfDim).reshaped(1, 1, -1)
        let exponent = adim.asType(.float32) / Float(halfDim - 1)
        let phase = positions / MLX.pow(MLXArray(maxPeriod), exponent)
        return MLX.concatenated([MLX.cos(phase), MLX.sin(phase)], axis: -1)
    }
    
    func callAsFunction(
        audioTokens: MLXArray,
        conditioning: MLXArray,
        cache: inout [MusicGenKVCache?]
    ) -> MLXArray {
        var x = emb[0](audioTokens[0..., 0])
        for k in 1..<numCodebooks {
            x = x + emb[k](audioTokens[0..., k])
        }
        
        let offset = cache[0]?.offset ?? 0
        let posEmb = createSinEmbedding(positions: MLXArray(Float(offset)), dim: hiddenSize)
        x = x + posEmb.asType(x.dtype)
        for i in 0..<layers.count {
            x = layers[i](x, conditioning: conditioning, cache: cache[i])
        }
        
        x = outNorm(x)
        let projected = linears.map { $0(x) }
        return MLX.stacked(projected, axis: -1)
    }
    
}


// MARK: - Multi-Head Attention

class MusicGenMultiHeadAttention: Module {
    let numHeads: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(dim: Int, numHeads: Int) {
        self.numHeads = numHeads
        let headDim = dim / numHeads
        self.scale = pow(Float(headDim), -0.5)
        self._qProj.wrappedValue = Linear(dim, dim, bias: false)
        self._kProj.wrappedValue = Linear(dim, dim, bias: false)
        self._vProj.wrappedValue = Linear(dim, dim, bias: false)
        self._outProj.wrappedValue = Linear(dim, dim, bias: false)
    }

    func callAsFunction(
        queries: MLXArray,
        keys: MLXArray,
        values: MLXArray,
        mask: MLXArray? = nil,
        cache: MusicGenKVCache? = nil
    ) -> MLXArray {
        let B = queries.dim(0)
        let Lq = queries.dim(1)
        let Lk = keys.dim(1)

        var q = qProj(queries)
        var k = kProj(keys)
        var v = vProj(values)

        q = q.reshaped(B, Lq, numHeads, -1).transposed(0, 2, 1, 3)
        k = k.reshaped(B, Lk, numHeads, -1).transposed(0, 2, 1, 3)
        v = v.reshaped(B, Lk, numHeads, -1).transposed(0, 2, 1, 3)

        if let cache = cache {
            (k, v) = cache.updateAndFetch(keys: k, values: v)
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: scale, mask: mask
        )
        let reshaped = output.transposed(0, 2, 1, 3).reshaped(B, Lq, -1)
        return outProj(reshaped)
    }
}

// MARK: - Transformer Block

class MusicGenTransformerDecoderLayer: Module {
    let numAttentionHeads: Int
    let hiddenSize: Int

    @ModuleInfo(key: "self_attn") var selfAttn: MusicGenMultiHeadAttention
    @ModuleInfo(key: "cross_attn") var crossAttn: MusicGenMultiHeadAttention
    @ModuleInfo var linear1: Linear
    @ModuleInfo var linear2: Linear
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo(key: "norm_cross") var normCross: LayerNorm
    @ModuleInfo var norm2: LayerNorm

    init(numAttentionHeads: Int, hiddenSize: Int, dimFFN: Int) {
        self.numAttentionHeads = numAttentionHeads
        self.hiddenSize = hiddenSize

        self._selfAttn.wrappedValue = MusicGenMultiHeadAttention(
            dim: hiddenSize, numHeads: numAttentionHeads
        )
        self._crossAttn.wrappedValue = MusicGenMultiHeadAttention(
            dim: hiddenSize, numHeads: numAttentionHeads
        )
        self._linear1.wrappedValue = Linear(hiddenSize, dimFFN, bias: false)
        self._linear2.wrappedValue = Linear(dimFFN, hiddenSize, bias: false)
        self._norm1.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: 1e-5)
        self._normCross.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: 1e-5)
        self._norm2.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: 1e-5)
    }

    func callAsFunction(
        _ x: MLXArray,
        conditioning: MLXArray,
        mask: MLXArray? = nil,
        cache: MusicGenKVCache? = nil
    ) -> MLXArray {
        
        let xn1 = norm1(x)
        var x = x + selfAttn(queries: xn1, keys: xn1, values: xn1, mask: mask, cache: cache)
        let xn2 = normCross(x)
        x = x + crossAttn(queries: xn2, keys: conditioning, values: conditioning, mask: mask)
        let xn3 = norm2(x)
        x = x + linear2(gelu(linear1(xn3)))
        return x
    }
}



class MusicGenKVCache {
    let nKvHeads: Int
    let kHeadDim: Int
    let vHeadDim: Int
    var keys: MLXArray?
    var values: MLXArray?
    var offset: Int = 0
    let step: Int = 256

    init(headDim: Int, nKvHeads: Int) {
        self.nKvHeads = nKvHeads
        self.kHeadDim = headDim
        self.vHeadDim = headDim
    }

    func updateAndFetch(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let prev = offset
        if keys == nil || (prev + newKeys.dim(2)) > keys!.dim(2) {
            let B = newKeys.dim(0)
            let nSteps = (step + newKeys.dim(2) - 1) / step
            let kShape = [B, nKvHeads, nSteps * step, kHeadDim]
            let vShape = [B, nKvHeads, nSteps * step, vHeadDim]
            var newK = MLXArray.zeros(kShape).asType(newKeys.dtype)
            var newV = MLXArray.zeros(vShape).asType(newValues.dtype)
            if let existingKeys = keys {
                var ek = existingKeys
                var ev = values!
                if prev % step != 0 {
                    ek = ek[0..., 0..., 0 ..< prev, 0...]
                    ev = ev[0..., 0..., 0 ..< prev, 0...]
                }
                newK = concatenated([ek, newK], axis: 2)
                newV = concatenated([ev, newV], axis: 2)
            }
            keys = newK
            values = newV
        }

        offset += newKeys.dim(2)
        keys![0..., 0..., prev ..< offset, 0...] = newKeys
        values![0..., 0..., prev ..< offset, 0...] = newValues
        return (keys![0..., 0..., 0 ..< offset, 0...], values![0..., 0..., 0 ..< offset, 0...])
    }
}
