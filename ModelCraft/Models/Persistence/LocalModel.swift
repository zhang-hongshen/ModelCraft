//
//  LocalModel.swift
//  ModelCraft
//
//  Created by Hongshen on 2/3/26.
//

import Foundation
import Observation

import Hub

struct LocalModel: ModelEntity, Hashable, Sendable {
    
    let id: String
    
    let createdAt: Date
    
    let size: Int64
    
    init(id: String, size: Int64, createdAt: Date = .now) {
        self.id = id
        self.size = size
        self.createdAt = createdAt
    }
    
}

@MainActor
@Observable
final class LocalModelStore {

    private(set) var models: [LocalModel]

    private let modelsDirectory: URL
    private let fileManager: FileManager

    init(
        models: [LocalModel] = [],
        modelsDirectory: URL = HubApi.defaultModelsDirectory,
        fileManager: FileManager = .default
    ) {
        self.models = models
        self.modelsDirectory = modelsDirectory
        self.fileManager = fileManager
    }

    func contains(_ modelID: String) -> Bool {
        models.contains { $0.id == modelID }
    }

    func reload() {
        models = discoverModels()
    }

    private func discoverModels() -> [LocalModel] {
        guard let authors = try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return authors.flatMap { authorDirectory -> [LocalModel] in
            guard isDirectory(authorDirectory),
                  let modelDirectories = try? fileManager.contentsOfDirectory(
                    at: authorDirectory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .creationDateKey,
                        .contentModificationDateKey,
                    ],
                    options: [.skipsHiddenFiles]
                  ) else {
                return []
            }

            return modelDirectories.compactMap { modelDirectory in
                let modelID = "\(authorDirectory.lastPathComponent)/\(modelDirectory.lastPathComponent)"
                guard isDirectory(modelDirectory),
                      !ToolDefinition.modelIDs.contains(modelID) else {
                    return nil
                }
                let values = try? modelDirectory.resourceValues(forKeys: [
                    .creationDateKey,
                    .contentModificationDateKey,
                ])
                return LocalModel(
                    id: modelID,
                    size: directorySize(at: modelDirectory),
                    createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast
                )
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func directorySize(at directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        return enumerator.reduce(into: Int64(0)) { result, item in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                  ]),
                  values.isRegularFile == true else {
                return
            }
            result += Int64(values.fileSize ?? 0)
        }
    }
}
