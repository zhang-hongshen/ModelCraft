//
//  OllamaClient.swift
//
//
//  Created by Kevin Hermawan on 10/11/23.
//

import Foundation

/// Provides a streamlined way to access the Ollama API, encapsulating the complexities of network communication and data processing.
///
/// Usage of ``OllamaClient`` involves initializing it with the base URL of the Ollama API. This setup configures the internal router and decoder for handling API interactions.
///
/// ```swift
/// let baseURL = URL(string: "http://localhost:11434")!
/// let OllamaClient = OllamaClient(baseURL: baseURL)
/// ```
///
/// - Initialization:
///   - `init(baseURL: URL)`: Initializes a new instance of ``OllamaClient`` with the provided base URL for the Ollama API.
public struct OllamaClient {
    
    var router: Router.Type
    var decoder: JSONDecoder = .default
    
    public init(baseURL: URL) {
        let router = Router.self
        router.baseURL = baseURL
        
        self.router = router
    }
}
