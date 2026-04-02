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

class ModelService {
    
    static let shared = ModelService()
    
    private let baseURL = "https://huggingface.co/api"
    
    func searchModel(keyword: String, page: Int = 0, pageSize: Int = 20) async throws -> [ModelStoreModel] {
        var parameters: [String: Any] = [
            "author": "mlx-community",
            "filter": "mlx",
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
    
    func  downloadModel(modelID: String) -> AsyncThrowingStream<Progress, Error> {
        
        let repo = Hub.Repo(id: modelID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await HubApi.default.snapshot(from: repo) { progress in
                        print("modelID:\(modelID) progress:\(progress.fractionCompleted)")
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
    
    func deleteModel(modelID: String) throws {
        let modelFolder = URL.applicationSupportDirectory
            .appendingPathComponent("huggingface", conformingTo: .folder)
            .appendingPathComponent(modelID, conformingTo: .folder)
        try FileManager.default.removeItem(at: modelFolder)
    }
    
}
