//
//  KnowledgaBaseModelActor.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 5/4/2024.
//

import Foundation
import SwiftData

@ModelActor
actor KnowledgaBaseModelActor {
    
    func insert(_ model: KnowledgeBase) {
        modelContext.insert(model)
        try? modelContext.save()
        Task.detached {
            model.embed()
        }
    }
    
    func delete(_ model: KnowledgeBase) {
        modelContext.delete(model)
        try? modelContext.save()
        Task.detached {
            model.clear()
        }
    }
}
