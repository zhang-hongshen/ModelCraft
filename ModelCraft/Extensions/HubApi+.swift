//
//  HubApi+.swift
//  ModelCraft
//
//  Created by Hongshen on 17/5/26.
//

import Foundation

import Hub
import MLXLMCommon


extension HubApi {

    static var downloadBaseDirectory: URL {
        UserDefaultSettings.modelDownloadBaseDirectory
    }

    static var modelsDirectory: URL {
        downloadBaseDirectory.appending(path: "models")
    }

    public static var `default`: HubApi {
        HubApi(downloadBase: downloadBaseDirectory)
    }

    /// The app's own image, video, music, and voice models live under `<base>/.system/models`,
    /// apart from the chat models users download into `<base>/models`.
    public static var system: HubApi {
        HubApi(downloadBase: downloadBaseDirectory.appending(path: ".system"))
    }

    /// Moves app models downloaded before they had their own folder out of `<base>/models`.
    static func moveSystemModels(ids: some Sequence<String>) {
        let fileManager = FileManager.default
        for id in ids {
            let source = HubApi.default.localRepoLocation(Repo(id: id))
            let destination = HubApi.system.localRepoLocation(Repo(id: id))
            guard fileManager.fileExists(at: source), !fileManager.fileExists(at: destination) else {
                continue
            }
            try? fileManager.moveDirectory(at: source, to: destination)
        }
    }

    /// Loads a model from its local snapshot, downloading the files matching `globs` when
    /// the snapshot is missing or incomplete.
    func loadModel<Model>(
        id: String,
        matching globs: [String],
        using load: (URL) async throws -> Model
    ) async throws -> Model {
        let repo = Repo(id: id)
        do {
            return try await load(localRepoLocation(repo))
        } catch {
            return try await load(snapshot(from: repo, matching: globs))
        }
    }
}

/// Lets MLX model loading download into the same base directory as the rest of the app.
extension HubApi: @retroactive Downloader {

    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await snapshot(
            from: Repo(id: id),
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler)
    }
}
