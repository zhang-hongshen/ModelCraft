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
    
    /// Type of the model (language or vision-language)
    var type: ModelType

    /// Defines the type of language model
    enum ModelType: String, Codable {
        /// Large language model (text-only)
        case llm
        /// Vision-language model (supports images and text)
        case vlm
    }
    
    init(id: String, size: Int64, type: ModelType) {
        self.id = id
        self.size = size
        self.type = type
    }
    
}
