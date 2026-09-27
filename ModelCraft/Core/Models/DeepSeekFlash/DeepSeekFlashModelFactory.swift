//
//  DeepSeekFlashModelFactory.swift
//  ModelCraft
//
//  Created by Hongshen on 27/9/26.
//

import Foundation
import Hub
import MLXLMCommon

actor DeepSeekFlashModelFactory {
    private enum LoadState {
        case idle
        case loading(maximumSequenceLength: Int, task: Task<DeepSeekFlash, Error>)
        case loaded(DeepSeekFlash)
    }

    private var state = LoadState.idle

    func load(
        hub: HubApi = .default,
        maximumSequenceLength: Int
    ) async throws -> DeepSeekFlash {
        try Task.checkCancellation()
        switch state {
        case .loaded(let model) where model.maximumSequenceLength == maximumSequenceLength:
            return model
        case .loading(let length, let task) where length == maximumSequenceLength:
            return try await waitForLoad(task)
        case .loading(_, let task):
            do {
                let model = try await waitForLoad(task)
                state = .loaded(model)
            } catch {
                state = .idle
            }
            try Task.checkCancellation()
            return try await load(hub: hub, maximumSequenceLength: maximumSequenceLength)
        case .idle, .loaded(_):
            let task = Task<DeepSeekFlash, Error> {
                let configuration: DeepSeekFlashConfiguration
                do {
                    configuration = try DeepSeekFlashLoader.loadConfiguration(hub: hub)
                } catch {
                    try await DeepSeekFlashConfiguration.download(hub: hub)
                    configuration = try DeepSeekFlashLoader.loadConfiguration(hub: hub)
                }
                try Task.checkCancellation()
                return try await DeepSeekFlash(
                    hub: hub,
                    configuration: configuration,
                    maximumSequenceLength: maximumSequenceLength)
            }
            state = .loading(maximumSequenceLength: maximumSequenceLength, task: task)
            do {
                let model = try await waitForLoad(task)
                state = .loaded(model)
                return model
            } catch {
                state = .idle
                throw error
            }
        }
    }

    func tokenCount(
        prompt: String,
        images: [UserInput.Image],
        hub: HubApi = .default
    ) async throws -> Int {
        switch state {
        case .loaded(let model):
            return try model.tokenCount(prompt: prompt, images: images)
        case .loading(_, let task):
            let model = try await waitForLoad(task)
            state = .loaded(model)
            return try model.tokenCount(prompt: prompt, images: images)
        case .idle:
            let configuration = try DeepSeekFlashLoader.loadConfiguration(hub: hub)
            let directory = hub.localRepoLocation(
                Hub.Repo(id: DeepSeekFlashConfiguration.repositoryID))
            let tokenizer = try await DeepSeekFlashTokenizer(
                hub: hub, directory: directory)
            return try DeepSeekFlashImageProcessor.prepare(
                promptTokenIDs: tokenizer.encode(text: prompt),
                images: images,
                imagePlaceholderTokenID: tokenizer.imagePlaceholderTokenID,
                configuration: configuration)
                .tokenIDs.count
        }
    }

    private func waitForLoad(
        _ task: Task<DeepSeekFlash, Error>
    ) async throws -> DeepSeekFlash {
        try await withTaskCancellationHandler {
            let model = try await task.value
            try Task.checkCancellation()
            return model
        } onCancel: {
            task.cancel()
        }
    }
}
