//
//  LocalModel.swift
//  ModelCraft
//
//  Created by Hongshen on 2/3/26.
//

import SwiftData
import Foundation

@Model
class LocalModel {
    
    @Attribute(.unique) var modelID: String
    
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
    
    init(modelID: String, size: Int64, type: ModelType) {
        self.modelID = modelID
        self.size = size
        self.type = type
    }
    
}


extension LocalModel {
    
    var displayName: String {
        modelID.components(separatedBy: "/").last ?? modelID
    }
}
