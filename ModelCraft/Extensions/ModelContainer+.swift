//
//  ModelContainer+.swift
//  ModelCraft
//
//  Created by Hongshen on 20/2/26.
//

import SwiftData

extension ModelContainer {
    
    static let shared: ModelContainer = {
        let schema = Schema([
            Message.self, Chat.self, ModelTask.self,
            KnowledgeBase.self
        ])
#if DEBUG
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
#else
        let modelConfiguration = ModelConfiguration(schema: schema)
#endif

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}
