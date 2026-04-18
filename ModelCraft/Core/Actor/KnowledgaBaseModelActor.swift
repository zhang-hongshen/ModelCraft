//
//  KnowledgaBaseModelActor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/4/2024.
//

import Foundation
import SwiftData

@ModelActor
actor ProjectModelActor {
    
    func insert(_ model: Project) {
        modelContext.persist(model)
    }
    
    func delete(_ model: Project) {
        modelContext.delete(model)
        try? modelContext.save()
        Task.detached {
            model.clear()
        }
    }
    
    func searchRelevantDocuments(projectID: PersistentIdentifier, query: String, numOfResults: Int? = nil) async -> [String]{
        guard let project = modelContext.model(for: projectID) as? Project else { return [] }
        return await project.search(query: query, numOfResults: numOfResults ?? 10)
    }
}
