//
//  ProjectModelActor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/4/2024.
//

import SwiftData

@ModelActor
actor ProjectModelActor {

    func searchProject(
        projectID: PersistentIdentifier,
        query: String,
        purpose: ProjectSearchPurpose,
        numOfResults: Int? = nil
    ) async -> [ProjectSearchResult] {
        guard let project = modelContext.model(for: projectID) as? Project else { return [] }
        return await project.search(
            query: query,
            purpose: purpose,
            numOfResults: numOfResults ?? 10)
    }
}
