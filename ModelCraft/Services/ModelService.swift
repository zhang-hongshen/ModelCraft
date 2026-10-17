//
//  ModelService.swift
//  ModelCraft
//
//  Created by Hongshen on 28/2/26.
//

import Foundation

import Hub
import Alamofire
import MLXLMCommon

enum ModelService {
    
    private static let baseURL = "https://huggingface.co/api"
    
    static func searchModel(keyword: String, category: ModelCategory, page: Int = 0, pageSize: Int = 20) async throws -> [ModelStoreModel] {
        var parameters: [String: Any] = [
            "author": "mlx-community",
            "filter": "mlx",
            "pipeline_tag": category.rawValue,
            "sort": "downloads",
            "direction": "-1",
            "limit": pageSize,
            "skip": page * pageSize,
        ]
        
        if !keyword.isEmpty {
            parameters["search"] = keyword
        }
        
        return try await AF.request(baseURL + "/models", method: .get, parameters: parameters)
                .validate()
                .serializingDecodable([ModelStoreModel].self, decoder: JSONDecoder.default)
                .value
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
    
    static func downloadModel(hub: HubApi = .default, modelID: String) -> AsyncThrowingStream<Progress, Error> {
        let repo = Hub.Repo(id: modelID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    
                    _ = try await hub.snapshot(from: repo) { progress in
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
    
    static func deleteModel(hub: HubApi = .default, modelID: String) throws {
        let modelFolder = hub.localRepoLocation(.init(id: modelID))
        try FileManager.default.removeItem(at: modelFolder)
    }
    
}
