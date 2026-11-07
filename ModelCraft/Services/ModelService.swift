//
//  ModelService.swift
//  ModelCraft
//
//  Created by Hongshen on 28/2/26.
//

import Foundation

import HuggingFace
import Alamofire
import MLXLMCommon
import MLXLLM
import MLXVLM

enum ModelService {
    
    private static let baseURL = "https://huggingface.co/api"
    
    static func searchModel(keyword: String, category: ModelCategory, page: Int = 0, pageSize: Int = 20) async throws -> (models: [ModelStoreModel], hasMore: Bool) {
        var parameters: [String: Any] = [
            "author": "mlx-community",
            "filter": "mlx",
            "config": true,
            "pipeline_tag": category.rawValue,
            "sort": "downloads",
            "direction": "-1",
            "limit": pageSize,
            "skip": page * pageSize,
        ]
        
        if !keyword.isEmpty {
            parameters["search"] = keyword
        }
        
        let candidates = try await AF.request(baseURL + "/models", method: .get, parameters: parameters)
                .validate()
                .serializingDecodable([ModelStoreModel].self, decoder: JSONDecoder.default)
                .value

        var supportedModels: [ModelStoreModel] = []
        for model in candidates {
            try Task.checkCancellation()
            guard let modelType = model.config?.modelType else { continue }
            if await LLMTypeRegistry.shared.contains(modelType) {
                supportedModels.append(model)
            } else if await VLMTypeRegistry.shared.contains(modelType) {
                supportedModels.append(model)
            }
        }
        return (supportedModels, candidates.count == pageSize)
    }
    
    /// The search endpoint cannot return `usedStorage`, so it is requested per model with
    /// `expand[]=usedStorage`, which returns only that field.
    static func fetchUsedStorage(modelID: String) async throws -> Int64 {
        struct Response: Decodable {
            let usedStorage: Int64
        }
        return try await AF.request(baseURL + "/models/\(modelID)", method: .get, parameters: ["expand[]": "usedStorage"])
                .validate()
                .serializingDecodable(Response.self, automaticallyCancelling: true)
                .value
                .usedStorage
    }
    
    /// Redirects to the organization's avatar image.
    static func avatarURL(organization: String) -> URL? {
        URL(string: baseURL + "/organizations/\(organization)/avatar?redirect=true")
    }
    
    static func downloadModel(hub: HubCache = .default, modelID: String) -> AsyncThrowingStream<Progress, Error> {
        let repo = modelID
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    
                    _ = try await hub.downloadSnapshot(id: repo) { progress in
                        print("\(modelID) \(progress.fractionCompleted)")
                        continuation.yield(progress)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    static func deleteModel(hub: HubCache = .default, modelID: String) throws {
        guard let repo = Repo.ID(rawValue: modelID) else {
            throw HubCacheError.cachedPathResolutionFailed(modelID)
        }
        let cacheDirectory = hub.repoDirectory(repo: repo, kind: .model)
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.removeItem(at: cacheDirectory)
        }
    }
    
}
