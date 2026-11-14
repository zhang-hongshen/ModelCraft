//
//  HubCache+.swift
//  ModelCraft
//

import Foundation
import HuggingFace
import MLXLMCommon

extension HubCache {
    /// Cache for models downloaded automatically by app features.
    static let system = HubCache(
        cacheDirectory: HubCache.default.cacheDirectory.appendingPathComponent(".system", isDirectory: true))

    func cachedModelDirectory(id: String, revision: String = "main") -> URL? {
        guard let repo = Repo.ID(rawValue: id),
              let commit = resolveRevision(repo: repo, kind: .model, ref: revision),
              let directory = try? snapshotPath(repo: repo, kind: .model, commitHash: commit),
              FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return directory
    }

    func modelDirectory(id: String) throws -> URL {
        guard let directory = cachedModelDirectory(id: id) else {
            throw HubCacheError.cachedPathResolutionFailed(id)
        }
        return directory
    }

    /// Returns the shared cache snapshot without a per-app output copy.
    @discardableResult
    func downloadSnapshot(
        id: String,
        revision: String = "main",
        matching globs: [String] = [],
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw HubCacheError.cachedPathResolutionFailed(id)
        }
        try Task.checkCancellation()
        return try await HubClient(cache: self).downloadSnapshot(
            of: repo, revision: revision, matching: globs,
            progressHandler: { progressHandler($0) })
    }

    func loadModel<Model>(
        id: String,
        matching globs: [String],
        using load: (URL) async throws -> Model
    ) async throws -> Model {
        do {
            return try await load(modelDirectory(id: id))
        } catch {
            try Task.checkCancellation()
            let directory = try await downloadSnapshot(id: id, matching: globs)
            return try await load(directory)
        }
    }
}

extension HubCache: @retroactive Downloader {
    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await downloadSnapshot(
            id: id, revision: revision ?? "main", matching: patterns,
            progressHandler: progressHandler)
    }
}
