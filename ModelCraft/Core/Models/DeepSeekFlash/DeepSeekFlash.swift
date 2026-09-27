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

    let configuration: DeepSeekFlashConfiguration
    private let tokenizer: DeepSeekFlashTokenizer
    let transformer: DeepSeekFlashTransformer

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

    func generate(
        prompt: String,
        images: [UserInput.Image] = [],
        maximumNewTokens: Int? = nil,
        temperature: Float = 1
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

                do {
                    let generated = try generateTokenIDs(
                        tokenIDs: promptTokenIDs,
                        images: prepared.images,
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
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func generateTokenIDs(
        tokenIDs: [Int],
        images: [DeepSeekFlashImageInput],
        maximumNewTokens: Int,
        temperature: Float = 1,
        endOfSentenceTokenID: Int = 1,
        onToken: ((Int) -> Void)? = nil
    ) throws -> [Int] {
        precondition(!tokenIDs.isEmpty, "DeepSeekFlash requires at least one prompt token")
        guard maximumNewTokens > 0 else { return [] }

        transformer.resetCache(batchSize: 1)
        let prefill = try transformer(
            MLXArray(tokenIDs).reshaped([1, tokenIDs.count]),
            images: images,
            startPosition: 0,
            temperature: temperature)
        eval(prefill.tokenIDs)

        var generated = [Int]()
        generated.reserveCapacity(maximumNewTokens)
        var currentTokenIDs = prefill.tokenIDs
        var currentToken = Int(currentTokenIDs.asArray(Int32.self)[0])
        guard currentToken != endOfSentenceTokenID else { return generated }
        generated.append(currentToken)
        onToken?(currentToken)

        guard generated.count < maximumNewTokens else {
            return generated
        }

        if let mainHidden = prefill.dsparkHidden {
            eval(mainHidden)
            _ = try transformer.forwardSpeculative(
                inputIDs: currentTokenIDs,
                mainHidden: mainHidden,
                startPosition: 0,
                temperature: 0)
        }

        var activeDrafts = [Int]()
        var activeDraftIndex = 0
        var position = tokenIDs.count

        while generated.count < maximumNewTokens {
            try Task.checkCancellation()
            let main = try transformer(
                currentTokenIDs.reshaped([1, 1]),
                startPosition: position,
                temperature: temperature)
            eval(main.tokenIDs)
            let verifiedToken = Int(main.tokenIDs.asArray(Int32.self)[0])

            var latestDrafts = [Int]()
            if let mainHidden = main.dsparkHidden {
                eval(mainHidden)
                if let draft = try transformer.forwardSpeculative(
                    inputIDs: main.tokenIDs,
                    mainHidden: mainHidden,
                    startPosition: position,
                    temperature: 0)
                {
                    eval(draft.tokenIDs, draft.confidence)
                    latestDrafts = Array(
                        draft.tokenIDs.asArray(Int32.self).dropFirst().map(Int.init))
                }
            }

            if activeDraftIndex < activeDrafts.count,
               activeDrafts[activeDraftIndex] == verifiedToken
            {
                activeDraftIndex += 1
                if activeDraftIndex == activeDrafts.count {
                    activeDrafts = latestDrafts
                    activeDraftIndex = 0
                }
            } else {
                activeDrafts = latestDrafts
                activeDraftIndex = 0
            }

            currentTokenIDs = main.tokenIDs
            currentToken = verifiedToken
            if currentToken == endOfSentenceTokenID {
                break
            }
            generated.append(currentToken)
            onToken?(currentToken)
            position += 1
        }

        return generated
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
