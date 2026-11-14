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
    
    @MainActor
    static func searchModel(keyword: String, category: ModelCategory, page: Int = 0, pageSize: Int = 20) async throws -> (models: [ModelStoreModel], hasMore: Bool) {
        var parameters: [String: Any] = [
            "author": "mlx-community",
            "filter": "mlx",
            "expand": ["config", "downloads", "tags", "pipeline_tag", "safetensors", "sha"],
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
                .serializingDecodable([ModelStoreModel].self, automaticallyCancelling: true, decoder: JSONDecoder.default)
                .value

        var supportedModels: [ModelStoreModel] = []
        for model in candidates {
            try Task.checkCancellation()
            guard model.pipelineTag == category.rawValue, model.isConversationModel(),
                  let modelType = model.config?.modelType else { continue }
            if await LLMTypeRegistry.shared.contains(modelType) {
                supportedModels.append(model)
            } else if await VLMTypeRegistry.shared.contains(modelType) {
                supportedModels.append(model)
            }
        }
        // Every result is assessed, including models currently hidden by the local
        // rating filter. Four sequential metadata workers bound network concurrency.
        let models = try await withThrowingTaskGroup(of: (Int, ModelStoreModel?).self) { group in
            var next = 0
            var prepared: [(Int, ModelStoreModel?)] = []
            while next < min(4, supportedModels.count) {
                let index = next
                let model = supportedModels[index]
                group.addTask { (index, try await prepareStoreModel(model)) }
                next += 1
            }
            for try await result in group {
                prepared.append(result)
                if next < supportedModels.count {
                    let index = next
                    let model = supportedModels[index]
                    group.addTask { (index, try await prepareStoreModel(model)) }
                    next += 1
                }
            }
            return prepared.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        }
        return (models, candidates.count == pageSize)
    }
    
    @MainActor
    private static var storeAssessments: [String: ModelStoreModel.Assessment] = [:]

    private struct StoreRepository: Decodable, Sendable {
        let siblings: [File]
        let safetensors: ModelStoreModel.SafeTensors?

        struct File: Decodable, Sendable {
            let rfilename: String
            let size: Int64?
            let lfs: LFS?

            struct LFS: Decodable, Sendable {
                let size: Int64
            }

            var byteCount: Int64? { size ?? lfs?.size }
        }

        /// downloadSnapshot downloads this revision's files, not historical blobs.
        var downloadSizeInBytes: Int64? {
            totalSize(of: siblings.map(\.rfilename))
        }

        /// A single, complete root checkpoint. Do not combine alternate weights.
        var canonicalWeightBytes: Int64? {
            let names = siblings.map(\.rfilename).filter { !$0.contains("/") && $0.hasSuffix(".safetensors") }
            if names == ["model.safetensors"] { return totalSize(of: names) }
            guard !names.isEmpty else { return nil }
            var shardNumbers: Set<Int> = []
            for name in names {
                guard let match = name.firstMatch(of: #/^model-(\d+)-of-(\d+)\.safetensors$/#),
                      let number = Int(match.1), let count = Int(match.2),
                      count == names.count, number > 0, number <= count else { return nil }
                shardNumbers.insert(number)
            }
            guard shardNumbers.count == names.count else { return nil }
            return totalSize(of: names)
        }

        func totalSize(of names: [String]) -> Int64? {
            guard !names.isEmpty else { return nil }
            let files = Dictionary(uniqueKeysWithValues: siblings.map { ($0.rfilename, $0) })
            var total: Int64 = 0
            for name in names {
                guard let size = files[name]?.byteCount, size >= 0 else { return nil }
                total += size
            }
            return total
        }
    }

    private struct StoreWeightIndex: Decodable, Sendable {
        let metadata: Metadata?
        let weightMap: [String: String]

        struct Metadata: Decodable, Sendable {
            let totalSize: Int64?
        }
    }

    @MainActor
    private static func prepareStoreModel(_ candidate: ModelStoreModel) async throws -> ModelStoreModel? {
        try Task.checkCancellation()
        var model = candidate
        let revision = model.sha ?? "main"
        let cacheKey = "\(model.id)@\(revision):\(model.pipelineTag ?? ""):\(ModelStoreHardware.current.modelMemoryBudget):v\(ModelStoreModel.Assessment.version)"
        if model.sha != nil, let assessment = storeAssessments[cacheKey] {
            model.assessment = assessment
            return model
        }

        var downloadSizeInBytes: Int64?
        do {
            guard let repository: StoreRepository = try await fetchStoreJSON(
                baseURL + "/models/\(model.id)/revision/\(revision)", parameters: ["blobs": "true"]
            ) else {
                model.assessment = model.assess(configuration: nil, weightBytes: nil, downloadSizeInBytes: nil)
                return model
            }
            downloadSizeInBytes = repository.downloadSizeInBytes
            let filesURL = "https://huggingface.co/\(model.id)/resolve/\(revision)/"
            let configuration: ModelStoreModel.Configuration? = try await fetchStoreJSON(filesURL + "config.json")
            guard model.isConversationModel(configuration: configuration) else { return nil }

            let names = Set(repository.siblings.map(\.rfilename))
            var weightBytes: Double?
            if names.contains("model.safetensors.index.json") {
                if let index: StoreWeightIndex = try await fetchStoreJSON(filesURL + "model.safetensors.index.json") {
                    let indexedFileSize = repository.totalSize(of: Array(Set(index.weightMap.values)))
                    if let fileSize = repository.canonicalWeightBytes ?? indexedFileSize, fileSize > 0 {
                        // Some MLX conversions retain the unquantized total_size.
                        // Trust the index only when it agrees with its actual shards
                        // (SafeTensors headers account for the small size difference).
                        if let indexedSize = index.metadata?.totalSize,
                           Double(indexedSize) >= Double(fileSize) * 0.99, indexedSize <= fileSize {
                            weightBytes = Double(indexedSize)
                        } else {
                            weightBytes = Double(fileSize)
                        }
                    }
                }
            } else if let size = repository.canonicalWeightBytes, size > 0 {
                weightBytes = Double(size)
            }
            // Hub dtype counts are useful when the canonical weight index is absent.
            // Never sum unrelated checkpoints/quantizations from the same repository.
            if weightBytes == nil, !names.contains("model.safetensors.index.json") {
                weightBytes = repository.safetensors?.weightBytes ?? model.safetensors?.weightBytes
            }
            let assessment = model.assess(
                configuration: configuration, weightBytes: weightBytes,
                downloadSizeInBytes: downloadSizeInBytes)
            try Task.checkCancellation()
            model.assessment = assessment
            // A failed metadata request is not cached. A new commit naturally misses.
            if model.sha != nil, configuration != nil, weightBytes != nil, downloadSizeInBytes != nil {
                storeAssessments[cacheKey] = assessment
            }
            return model
        } catch {
            try Task.checkCancellation()
            model.assessment = model.assess(configuration: nil, weightBytes: nil, downloadSizeInBytes: downloadSizeInBytes)
            return model
        }
    }

    /// Only JSON endpoints are used; weights are never fetched for assessment.
    private static func fetchStoreJSON<Value: Decodable & Sendable>(
        _ url: String, parameters: [String: String]? = nil
    ) async throws -> Value? {
        let response = await AF.request(url, parameters: parameters)
            .validate()
            .serializingDecodable(Value.self, automaticallyCancelling: true, decoder: JSONDecoder.default)
            .response
        try Task.checkCancellation()
        if response.response?.statusCode == 404 { return nil }
        return try response.result.get()
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
