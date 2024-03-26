//
//  ModelResponse.swift
//
//
//  Created by Kevin Hermawan on 10/11/23.
//

import Foundation

/// A structure that represents the available models from the Ollama API.
public struct ModelResponse: Decodable {
    /// An array of ``Model`` instances, each representing a specific model available in the Ollama API.
    public let models: [ModelInfo]
    
}
