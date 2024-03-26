//
//  OllamaClient+GenerateEmbeddings.swift
//
//
//  Created by Paul Thrasher on 02/09/24.
//

import Foundation
import Combine

import Alamofire

extension OllamaClient {
    /// Asynchronously generates embeddings from a specific model from the Ollama API.
    ///
    /// This method accepts ``GenerateEmbeddingsRequest`` and returns an ``GenerateEmbeddingsResponse`` containing embeddings from the requested model.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let requestData = GenerateEmbeddingsRequest(/* parameters */)
    /// let generateEmbeddings = try await OllamaClient.generateEmbeddings(data: requestData)
    /// ```
    ///
    /// - Parameter data: The ``GenerateEmbeddingsRequest`` used to query the API for generating specific model embeddings.
    /// - Returns: An ``GenerateEmbeddingsResponse`` containing the embeddings from the model.
    /// - Throws: An error if the request fails or the response can't be decoded.
    public func generateEmbeddings(data: GenerateEmbeddingsRequest) async throws -> GenerateEmbeddingsResponse {
        let request = AF.request(router.generateEmbeddings(data: data)).validate()
        let response = request.serializingDecodable(GenerateEmbeddingsResponse.self, decoder: decoder)
        let value = try await response.value
        
        return value
    }
    
    /// Retrieves embeddings from a specific model from the Ollama API as a Combine publisher.
    ///
    /// This method provides a reactive approach to generate embeddings. It accepts ``GenerateEmbeddingsRequest`` and returns a Combine publisher that emits an ``GenerateEmbeddingsResponse`` upon successful retrieval.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let requestData = GenerateEmbeddingsRequest(/* parameters */)
    ///
    /// OllamaClient.generateEmbeddings(data: requestData)
    ///     .sink(receiveCompletion: { completion in
    ///         // Handle completion
    ///     }, receiveValue: { generateEmbeddingsResponse in
    ///         // Handle the received model info response
    ///     })
    ///     .store(in: &cancellables)
    /// ```
    ///
    /// - Parameter data: The ``GenerateEmbeddingsRequest`` used to query the API for embeddings from a specific model.
    /// - Returns: A `AnyPublisher<GenerateEmbeddingsResponse, AFError>` that emits embeddings.
    public func generateEmbeddings(data: GenerateEmbeddingsRequest) -> AnyPublisher<GenerateEmbeddingsResponse, AFError> {
        let request = AF.request(router.generateEmbeddings(data: data)).validate()
        
        return request
            .publishDecodable(type: GenerateEmbeddingsResponse.self, decoder: decoder).value()
            .eraseToAnyPublisher()
    }
}
