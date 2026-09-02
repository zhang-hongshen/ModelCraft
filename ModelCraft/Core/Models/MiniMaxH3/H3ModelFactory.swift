//
//  H3ModelFactory.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//


import Foundation
import Hub

/// Lazily downloads and caches each H3 Base task through HubApi.
///
/// Both presets create the same ``H3Base`` type. Their cache entries are
/// separate because FL2VA and Ref2VA materialize different repository paths.
actor H3ModelFactory {
    private enum LoadState {
        case idle
        case loading(Task<H3Base, Error>)
        case loaded(H3Base)
    }

    private var states: [H3Configuration.Task: LoadState] = [:]

    func load(
        hub: HubApi = .default,
        configuration: H3Configuration,
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> H3Base {
        switch states[configuration.task] ?? .idle {
        case .loaded(let model):
            return model
        case .loading(let task):
            return try await task.value
        case .idle:
            let task = Task<H3Base, Error> {
                try await configuration.download(hub: hub, progressHandler: progressHandler)
                return try H3Base(hub: hub, configuration: configuration)
            }
            states[configuration.task] = .loading(task)
            do {
                let model = try await task.value
                states[configuration.task] = .loaded(model)
                return model
            } catch {
                states[configuration.task] = .idle
                throw error
            }
        }
    }

    func reset() {
        states.removeAll()
    }
}
