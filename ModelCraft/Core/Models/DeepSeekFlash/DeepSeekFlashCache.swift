//
//  DeepSeekFlashCache.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import MLX

/// The attention memory of one conversation: the main layers' and the DSpark stages' states, the
/// tokens committed to them, and a snapshot taken at the end of the last prompt. A later prompt
/// that shares a prefix resumes from the live states or from the snapshot instead of prefilling
/// from the first token.
final class DeepSeekFlashCache {
    private struct Checkpoint {
        let tokenCount: Int
        let states: [DeepSeekFlashAttentionState.Snapshot]
        let dsparkStates: [DeepSeekFlashAttentionState.Snapshot]
    }

    let maximumSequenceLength: Int
    let states: [DeepSeekFlashAttentionState]
    let dsparkStates: [DeepSeekFlashAttentionState]
    /// The tokens committed to the states, in order.
    private(set) var tokenIDs: [Int] = []
    /// The images placed within `tokenIDs`.
    private(set) var images: [DeepSeekFlashImageInput] = []
    private var checkpoint: Checkpoint?

    init(configuration: DeepSeekFlashConfiguration, maximumSequenceLength: Int) {
        self.maximumSequenceLength = maximumSequenceLength
        states = (0 ..< configuration.numHiddenLayers).map { layerID in
            DeepSeekFlashAttentionState(
                configuration: configuration,
                layerID: layerID,
                batchSize: 1,
                maximumSequenceLength: maximumSequenceLength)
        }
        dsparkStates = (0 ..< configuration.numNextPredictLayers).map { stageID in
            DeepSeekFlashAttentionState(
                configuration: configuration,
                layerID: configuration.numHiddenLayers + stageID,
                batchSize: 1,
                maximumSequenceLength: maximumSequenceLength)
        }
    }

    /// The memory a cache of `maximumSequenceLength` tokens occupies.
    static func byteCount(
        configuration: DeepSeekFlashConfiguration,
        maximumSequenceLength: Int
    ) -> Int {
        configuration.compressRatios.reduce(0) { total, ratio in
            let compressedCount = ratio == 0
                ? 0 : (maximumSequenceLength + ratio - 1) / ratio
            let indexBytes = ratio == 4
                ? compressedCount * configuration.indexHeadDimension * 2 : 0
            return total + indexBytes
                + (configuration.slidingWindow + compressedCount) * configuration.headDimension * 2
        }
    }

    var arrays: [MLXArray] {
        (states + dsparkStates).flatMap(\.arrays)
    }

    /// Commits the first `tokenIDs.count` tokens staged by the last forward pass.
    func commit(_ tokenIDs: [Int], images: [DeepSeekFlashImageInput] = []) {
        for state in states {
            state.commit(count: tokenIDs.count)
        }
        self.tokenIDs += tokenIDs
        self.images += images
        eval(arrays)
    }

    /// Remembers the current states so a later prompt that diverges after this point can return here.
    func saveCheckpoint() {
        checkpoint = Checkpoint(
            tokenCount: tokenIDs.count,
            states: states.map { $0.snapshot() },
            dsparkStates: dsparkStates.map { $0.snapshot() })
    }

    /// Prepares the states for `tokenIDs` and returns how many of its leading tokens they already
    /// hold. At least one token is always left to feed, and tokens holding a new image are never
    /// resumed past, because only a pass from the first token places images.
    func resume(tokenIDs newTokenIDs: [Int], images newImages: [DeepSeekFlashImageInput]) -> Int {
        let sharedCount = zip(tokenIDs, newTokenIDs).prefix { $0 == $1 }.count

        func canResume(at count: Int) -> Bool {
            guard count > 0, count < newTokenIDs.count else { return false }
            return newImages.allSatisfy { image in
                image.start + image.types.count <= count
                    && images.contains { held in
                        held.start == image.start
                            && held.types == image.types
                            && held.visionHeight == image.visionHeight
                            && held.visionWidth == image.visionWidth
                            && MLX.arrayEqual(held.patches, image.patches).item(Bool.self)
                    }
            }
        }

        if sharedCount == tokenIDs.count, canResume(at: sharedCount) {
            return sharedCount
        }
        if let checkpoint, checkpoint.tokenCount <= sharedCount,
           canResume(at: checkpoint.tokenCount)
        {
            for (state, snapshot) in zip(states, checkpoint.states) {
                state.restore(snapshot)
            }
            for (state, snapshot) in zip(dsparkStates, checkpoint.dsparkStates) {
                state.restore(snapshot)
            }
            tokenIDs.removeLast(tokenIDs.count - checkpoint.tokenCount)
            images.removeAll { $0.start + $0.types.count > checkpoint.tokenCount }
            return checkpoint.tokenCount
        }

        // Stale ring slots and compressed rows are never read before they are rewritten, so only
        // the compressor groups need clearing.
        for state in states + dsparkStates {
            state.reset()
        }
        tokenIDs = []
        images = []
        checkpoint = nil
        return 0
    }
}
