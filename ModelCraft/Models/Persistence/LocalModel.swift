//
//  LocalModel.swift
//  ModelCraft
//
//  Created by Hongshen on 2/3/26.
//

import SwiftData
import Foundation

@Model
class LocalModel: ModelEntity {
    
    @Attribute(.unique) var id: String
    
    var createdAt: Date = Date.now
    
    var size: Int64
    
    init(id: String, size: Int64) {
        self.id = id
        self.size = size
    }
    
}
