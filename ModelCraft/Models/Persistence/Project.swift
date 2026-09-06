//
//  Project.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/2024.
//

import Foundation
import SwiftData

@Model
class Project {
    @Attribute(.unique) var id = UUID()
    var createdAt: Date = Date.now
    var title: String
    
    @Relationship(deleteRule: .cascade, inverse: \Chat.project)
    var chats: [Chat] = []

    var workingDirectory: URL?
    var resources: [URL]
    
    init(title: String = "", workingDirectory: URL? = nil, resources: [URL] = []) {
        self.title = title
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.resources = resources.map(\.standardizedFileURL)
    }
}

extension Project {
    
    static func fetch(limit: Int? = nil, offset: Int? = nil) -> FetchDescriptor<Project> {
        var descriptor = FetchDescriptor<Project>()
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        descriptor.sortBy = [.init(\.createdAt, order: .reverse)]
        return descriptor
    }
}

extension Project {
    
    private var dbPath: String {
        let folder = URL.documentsDirectory
        return folder.appendingPathComponent("\(id.uuidString).fts5").path
    }
        
    func search(
        query: String,
        purpose: ProjectSearchPurpose = .automatic,
        numOfResults: Int = 10
    ) async -> [ProjectSearchResult] {
        await ProjectSearchIndex(dbPath: dbPath).search(
            query: query,
            purpose: purpose,
            workingDirectory: workingDirectory,
            resources: resources,
            limit: numOfResults)
    }
    
    func clear() {
        deleteIndex()
    }
    
    func removeIndex<T>(_ urls: T) where T: Swift.Collection, T.Element == URL {
        ProjectSearchIndex(dbPath: dbPath).remove(paths: urls.map(\.standardizedFileURL.path))
    }
    
    func addResources<T>(_ urls: T) where T: Swift.Collection, T.Element == URL {
        let addedResources = urls
            .map(\.standardizedFileURL)
            .filter { !resources.contains($0) }
        resources.append(contentsOf: addedResources)
    }
    

    func removeResources(atOffsets: IndexSet) {
        let urlsToRemove = atOffsets.map { resources[$0] }
        removeResources(urlsToRemove)
    }
    
    func removeResources<T>(_ urls: T) where T: Swift.Collection, T.Element == URL {
        let removedResources = urls.map(\.standardizedFileURL)
        resources.removeAll { removedResources.contains($0) }
        removeIndex(removedResources)
    }

    func deleteIndex() {
        let fileManager = FileManager.default
        for path in [dbPath, dbPath + "-shm", dbPath + "-wal"]
        where fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
    }
    
}
