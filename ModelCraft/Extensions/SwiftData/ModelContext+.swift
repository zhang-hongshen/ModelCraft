//
//  ModelContext+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 30/3/2024.
//

import SwiftData

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
    
    func delete<T, C: Collection>(_ models: C) where T : PersistentModel, C.Element == T  {
        for model in models {
            delete(model)
        }
    }
}
