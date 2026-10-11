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
        UserDefaults.standard.url(forKey: UserDefaults.modelDownloadBaseDirectory)
            ?? UserDefaultSettings.modelDownloadBaseDirectory
    }

    static var modelsDirectory: URL {
        downloadBaseDirectory.appending(path: "models")
    }

    public static var `default`: HubApi {
        HubApi(downloadBase: downloadBaseDirectory)
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
