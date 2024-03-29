//
//  CachedDataActor.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//
import Foundation
import SwiftData

@ModelActor
actor CachedDataActor {
    
    private(set) static var shared: CachedDataActor!
    
    static func configure(modelContainer: ModelContainer) {
        shared = CachedDataActor(modelContainer: modelContainer)
    }
    
    func fetch<T>(_ descriptor: FetchDescriptor<T>) throws -> [T] where T : PersistentModel {
        return try modelContext.fetch(descriptor)
    }
    
    func fetch<T>(_ descriptor: FetchDescriptor<T>, batchSize: Int) throws -> FetchResultsCollection<T> where T : PersistentModel  {
        return try modelContext.fetch(descriptor, batchSize: batchSize)
    }
    
    func persist<T>(_ model: T) where T : PersistentModel  {
        persist([model])
    }
    
    func persist<T>(_ models: [T])  where T : PersistentModel  {
        for model in models {
            modelContext.insert(model)
        }
        try? modelContext.save()
    }
    
    func delete<T>(_ model: T) where T : PersistentModel {
        delete([model])
    }
    
    func delete<T>(_ models: [T]) where T : PersistentModel {
        for model in models {
            modelContext.delete(model)
        }
        try? modelContext.save()
    }
    
    func delete<T>(model: T.Type, where predicate: Predicate<T>? = nil, includeSubclasses: Bool = true) throws where T : PersistentModel {
        try modelContext.delete(model: model, where: predicate, includeSubclasses: includeSubclasses)
        try modelContext.save()
    }
}

extension ModelContext {
    
    func persist<T>(_ model: T) where T : PersistentModel  {
        persist([model])
    }
    
    func persist<T>(_ models: [T])  where T : PersistentModel  {
        for model in models {
            insert(model)
        }
        try? save()
    }
    
    func delete<T>(_ models: [T])  where T : PersistentModel  {
        for model in models {
            delete(model)
        }
    }
}
