//
//  ModelInfo.swift
//
//
//  Created by 张鸿燊 on 22/3/2024.
//

import Foundation

/// A structure that details individual models.
public struct ModelInfo: Decodable, Hashable {
    /// A string representing the name of the model.
    public let name: String
    
    /// A string containing a digest or hash of the model, typically used for verification or identification.
    public let digest: String
    
    /// An integer indicating the size of the model, often in bytes.
    public let size: Int
    
    /// A `Date` representing the last modification date of the model.
    public let modifiedAt: Date
    
    /// A `ModelDetail` representing the detail of the model.
    public let details: ModelDetail
    
    init(name: String = "", digest: String = "", size: Int = 0,
         modifiedAt: Date = .now, details: ModelDetail = ModelDetail()) {
        self.name = name
        self.digest = digest
        self.size = size
        self.modifiedAt = modifiedAt
        self.details = details
    }
    
    public static func==(lhs: ModelInfo, rhs: ModelInfo) -> Bool {
        return lhs.digest == rhs.digest
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(digest)
    }
}

/// A structure that details individual models.
public struct ModelDetail: Decodable {
    
    public let parentModel: String
    
    public let format: String
    
    public let family: String
    
    public let families: [String]
    
    public let parameterSize: String
    
    public let quantizationLevel: String
    
    init(parentModel: String = "", format: String = "", family: String = "",
         families: [String] = [], parameterSize: String = "", quantizationLevel: String = "") {
        self.parentModel = parentModel
        self.format = format
        self.family = family
        self.families = families
        self.parameterSize = parameterSize
        self.quantizationLevel = quantizationLevel
    }
}
