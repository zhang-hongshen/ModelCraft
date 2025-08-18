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
        modelContext.persist(model)
        Task.detached {
            model.createEmedding()
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
