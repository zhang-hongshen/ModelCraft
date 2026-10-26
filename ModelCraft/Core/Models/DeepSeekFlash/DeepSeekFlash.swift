//
//  DeepSeekFlash.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import Foundation
import Hub
import MLX
import MLXLMCommon

struct DeepSeekFlashCompletionInfo: Sendable {
    let promptTokenCount: Int
    let generationTokenCount: Int
    let promptTime: TimeInterval
    let generationTime: TimeInterval
    let reachedTokenLimit: Bool
}

enum DeepSeekFlashGeneration: Sendable {
    case chunk(String)
    case info(DeepSeekFlashCompletionInfo)
}

final class DeepSeekFlash {
    /// Drafts whose confidence, as a probability, falls below this are not verified, so an unlikely
    /// draft does not make the main model read extra experts.
    private static let draftConfidenceThreshold: Float = 0.5

    let configuration: DeepSeekFlashConfiguration
    let tokenizer: DeepSeekFlashTokenizer
    let transformer: DeepSeekFlashTransformer
    /// The conversation memory for the next request that reuses its prompt. A running request
    /// takes it, so a concurrent one starts from a fresh cache instead of sharing it.
    private var promptCache: DeepSeekFlashCache?
    private let promptCacheLock = NSLock()

    var maximumSequenceLength: Int {
        transformer.maximumSequenceLength
    }

    init(
        hub: HubApi,
        configuration: DeepSeekFlashConfiguration,
        maximumSequenceLength: Int = 65_536
    ) async throws {
        self.configuration = configuration
        let directory = hub.localRepoLocation(
            Hub.Repo(id: DeepSeekFlashConfiguration.repositoryID))
        tokenizer = try await DeepSeekFlashTokenizer(hub: hub, directory: directory)
        transformer = try DeepSeekFlashLoader.loadTransformer(
            hub: hub,
            configuration: configuration,
            maximumSequenceLength: maximumSequenceLength)
    }

    func tokenCount(prompt: String, images: [UserInput.Image] = []) throws -> Int {
        try prepare(prompt: prompt, images: images).tokenIDs.count
    }

    /// Generates a reply to `prompt`. With `reusesPromptCache`, the request resumes from the
    /// longest prefix the previous such request left in memory and leaves its own for the next.
    func generate(
        prompt: String,
        images: [UserInput.Image] = [],
        maximumNewTokens: Int? = nil,
        temperature: Float = 1,
        reusesPromptCache: Bool = true
    ) -> AsyncThrowingStream<DeepSeekFlashGeneration, Error> {
        let prepared: DeepSeekFlashPreparedInput
        do {
            prepared = try prepare(prompt: prompt, images: images)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        let promptTokenIDs = prepared.tokenIDs
        let availableTokens = max(maximumSequenceLength - promptTokenIDs.count, 0)
        let generationLimit = max(min(maximumNewTokens ?? availableTokens, availableTokens), 0)

        return AsyncThrowingStream { continuation in
            let task = Task {
                let start = Date.timeIntervalSinceReferenceDate
                var promptTime: TimeInterval?
                let decoder = tokenizer.makeStreamingDecoder()
                let cache = reusesPromptCache
                    ? takePromptCache()
                    : DeepSeekFlashCache(
                        configuration: configuration,
                        maximumSequenceLength: promptTokenIDs.count + generationLimit)

                do {
                    let generated = try generateTokenIDs(
                        tokenIDs: promptTokenIDs,
                        images: prepared.images,
                        cache: cache,
                        maximumNewTokens: generationLimit,
                        temperature: temperature,
                        endOfSentenceTokenID: tokenizer.endOfSentenceTokenID
                    ) { token in
                        if promptTime == nil {
                            promptTime = Date.timeIntervalSinceReferenceDate - start
                        }
                        if let chunk = decoder.append(token: token) {
                            continuation.yield(.chunk(chunk))
                        }
                    }
                    if reusesPromptCache {
                        returnPromptCache(cache)
                    }

                    let totalTime = Date.timeIntervalSinceReferenceDate - start
                    let measuredPromptTime = promptTime ?? totalTime
                    continuation.yield(.info(DeepSeekFlashCompletionInfo(
                        promptTokenCount: promptTokenIDs.count,
                        generationTokenCount: generated.count,
                        promptTime: measuredPromptTime,
                        generationTime: max(totalTime - measuredPromptTime, 0),
                        reachedTokenLimit: generated.count >= generationLimit)))
                    continuation.finish()
                } catch {
                    // Cancellation stops between steps, so the cache is consistent; any other
                    // failure may have left a pass half committed.
                    if reusesPromptCache, error is CancellationError {
                        returnPromptCache(cache)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func takePromptCache() -> DeepSeekFlashCache {
        promptCacheLock.withLock {
            defer { promptCache = nil }
            return promptCache ?? DeepSeekFlashCache(
                configuration: configuration,
                maximumSequenceLength: maximumSequenceLength)
        }
    }

    private func returnPromptCache(_ cache: DeepSeekFlashCache) {
        promptCacheLock.withLock {
            promptCache = cache
        }
    }

    private func generateTokenIDs(
        tokenIDs: [Int],
        images: [DeepSeekFlashImageInput],
        cache: DeepSeekFlashCache,
        maximumNewTokens: Int,
        temperature: Float = 1,
        endOfSentenceTokenID: Int = 1,
        onToken: ((Int) -> Void)? = nil
    ) throws -> [Int] {
        precondition(!tokenIDs.isEmpty, "DeepSeekFlash requires at least one prompt token")
        guard maximumNewTokens > 0 else { return [] }

        var position = cache.resume(tokenIDs: tokenIDs, images: images)
        let promptSuffix = Array(tokenIDs[position...])
        let promptImages = position == 0 ? images : []
        let prefill = try transformer(
            MLXArray(promptSuffix).reshaped([1, promptSuffix.count]),
            images: promptImages,
            startPosition: position,
            cache: cache)
        cache.commit(promptSuffix, images: promptImages)
        transformer.observeDSpark(
            mainHidden: prefill.dsparkHidden,
            startPosition: tokenIDs.count - prefill.dsparkHidden.dim(1),
            cache: cache)
        cache.saveCheckpoint()
        position = tokenIDs.count

        var generated = [Int]()
        generated.reserveCapacity(maximumNewTokens)
        var currentToken = Int(DeepSeekFlashSampler.sample(
            logits: prefill.logits[0..., -1], temperature: temperature
        ).item(Int32.self))

        while currentToken != endOfSentenceTokenID {
            generated.append(currentToken)
            onToken?(currentToken)
            let room = min(
                maximumNewTokens - generated.count,
                cache.maximumSequenceLength - position)
            guard room > 0 else { break }
            try Task.checkCancellation()

            // Each accepted draft saves the main model one pass, and in particular one read of
            // the experts it routes to.
            var drafts = [Int]()
            if room > 1 {
                let draft = try transformer.draft(
                    currentTokenIDs: MLXArray([Int32(currentToken)]).reshaped([1, 1]),
                    startPosition: position,
                    cache: cache,
                    temperature: 0)
                let confidence = MLX.sigmoid(draft.confidence[0]).asArray(Float.self)
                let draftCount = min(
                    room - 1,
                    confidence.prefix { $0 >= Self.draftConfidenceThreshold }.count)
                drafts = Array(draft.tokenIDs[0].asArray(Int32.self)
                    .dropFirst().prefix(draftCount).map(Int.init))
            }

            let input = [currentToken] + drafts
            let output = try transformer(
                MLXArray(input).reshaped([1, input.count]),
                startPosition: position,
                cache: cache,
                allLogits: true,
                keepsStaged: true)
            let verification = Self.verify(
                logits: output.logits[0], drafts: drafts, temperature: temperature)
            let committed = Array(input.prefix(verification.acceptedCount + 1))
            cache.commit(committed)
            transformer.observeDSpark(
                mainHidden: output.dsparkHidden[0..., 0 ..< committed.count],
                startPosition: position,
                cache: cache)
            position += committed.count

            for token in drafts.prefix(verification.acceptedCount) {
                guard token != endOfSentenceTokenID else { return generated }
                generated.append(token)
                onToken?(token)
            }
            currentToken = verification.nextToken
        }

        return generated
    }

    /// Accepts the longest prefix of the greedy `drafts` that sampling from the main model's
    /// `logits` would also produce, keeping the main model's distribution, and samples the token
    /// that follows it.
    private static func verify(
        logits: MLXArray,
        drafts: [Int],
        temperature: Float
    ) -> (acceptedCount: Int, nextToken: Int) {
        if temperature == 0 {
            let targets = argMax(logits, axis: -1).asType(.int32).asArray(Int32.self)
                .map(Int.init)
            let acceptedCount = zip(drafts, targets).prefix { $0 == $1 }.count
            return (acceptedCount, targets[acceptedCount])
        }

        let probabilities = softmax(logits / temperature, axis: -1)
        var acceptedCount = 0
        if !drafts.isEmpty {
            let draftIndices = MLXArray(drafts.map(Int32.init)).reshaped([-1, 1])
            let draftProbabilities = takeAlong(
                probabilities[0 ..< drafts.count], draftIndices, axis: -1
            ).flattened()
            let draws = MLXRandom.uniform(0 ..< 1, [drafts.count])
            acceptedCount = (draws .< draftProbabilities).asArray(Bool.self)
                .prefix { $0 }.count
        }
        var residual = probabilities[acceptedCount]
        if acceptedCount < drafts.count {
            // A rejected greedy draft resamples from the main distribution without that token.
            residual[drafts[acceptedCount]] = MLXArray(Float(0))
        }
        let nextToken = MLXRandom.categorical(MLX.log(residual), axis: -1)
            .asType(.int32).item(Int32.self)
        return (acceptedCount, Int(nextToken))
    }

    private func prepare(
        prompt: String,
        images: [UserInput.Image]
    ) throws -> DeepSeekFlashPreparedInput {
        try DeepSeekFlashImageProcessor.prepare(
            promptTokenIDs: tokenizer.encode(text: prompt),
            images: images,
            imagePlaceholderTokenID: tokenizer.imagePlaceholderTokenID,
            configuration: configuration)
    }
}
