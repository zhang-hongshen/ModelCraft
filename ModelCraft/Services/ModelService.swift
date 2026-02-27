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
    
    func fetchModels(keyword: String, page: Int = 0, pageSize: Int = 20) async throws -> [LMModel] {
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
        
        let models = try await AF.request("https://huggingface.co/api/models",
                                          method: .get, parameters: parameters)
            .validate()
            .serializingDecodable([HuggingfaceModel].self, decoder: JSONDecoder.default)
            .value
        
        return models.map { model in
            let config = ModelConfiguration(id: model.id)
            
            return LMModel(
                name: model.id,
                configuration: config,
                type: model.isVLM ? .vlm : .llm
            )
        }
    }
    
    func download(modelId: String) -> AsyncThrowingStream<Progress, Error> {
        let repo = Hub.Repo(id: modelId)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await Hub.snapshot(from: repo) { progress in
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
}

struct HuggingfaceModel: Decodable {
    let id: String
    let modelId: String
    let downloads: Int
    let tags: [String]
    let pipelineTag: String?
    
    var isVLM: Bool {
        return pipelineTag == "image-text-to-text" || (pipelineTag?.contains("vision") ?? false)
    }
}

