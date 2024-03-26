//
//  PullModelRequest.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import Foundation

/// A structure that encapsulates the data necessary for pulling a specific model from the Ollama API.
public struct PullModelRequest: Encodable {
    /// A string representing the identifier of the model for which information is requested.
    public let name: String
    
    public init(name: String) {
        self.name = name
    }
}
