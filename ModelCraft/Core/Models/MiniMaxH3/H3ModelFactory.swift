// SPDX-License-Identifier: Apache-2.0

import Foundation
import Hub

/// Lazily downloads and caches each H3 Base task through HubApi.
///
/// Both presets create the same ``H3BaseModel`` type. Their cache entries are
/// separate because FL2VA and Ref2VA materialize different repository paths.
actor H3ModelFactory {
    private enum LoadState {
        case idle
        case loading(Task<H3BaseModel, Error>)
        case loaded(H3BaseModel)
    }

    private var states: [H3Configuration.Task: LoadState] = [:]

    func load(
        configuration: H3Configuration,
        hub: HubApi = .default,
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> H3BaseModel {
        switch states[configuration.task] ?? .idle {
        case .loaded(let model):
            return model
        case .loading(let task):
            return try await task.value
        case .idle:
            let task = Task<H3BaseModel, Error> {
                try await configuration.download(hub: hub, progressHandler: progressHandler)
                return try configuration.makeModel(hub: hub)
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
