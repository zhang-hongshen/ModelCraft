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
                return H3Base(hub: hub, configuration: configuration)
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

    /// Drops the cached model for a task and gives its weights back.
    ///
    /// A cached H3 Base holds every component it has loaded, up to the full
    /// 144 GB working set, so a caller that is done with H3 — or that needs the
    /// memory for another model family — releases it here instead of waiting for
    /// the process to exit.
    func evict(_ task: H3Configuration.Task) {
        if case .loaded(let model) = states[task] {
            model.cleanup()
        }
        states[task] = .idle
    }
}
