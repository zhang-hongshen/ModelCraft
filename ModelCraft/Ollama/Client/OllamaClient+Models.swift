//
//  OllamaClient+Models.swift
//
//
//  Created by Kevin Hermawan on 01/01/24.
//

import Foundation
import Combine
import Alamofire
import SwiftSoup

extension OllamaClient {
    /// Asynchronously retrieves a list of available models from the Ollama API.
    ///
    /// This method returns an ``ModelResponse`` containing the details of the available models.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let models = try await OllamaClient.models()
    /// ```
    ///
    /// - Returns: An ``ModelResponse`` object listing the available models.
    /// - Throws: An error if the request fails or the response can't be decoded.
    public func models() async throws -> ModelResponse {
        let request = AF.request(router.models).validate()
        let response = request.serializingDecodable(ModelResponse.self, decoder: decoder)
        let value = try await response.value
        
        return value
    }
    
    /// Retrieves a list of available models from the Ollama API as a Combine publisher.
    ///
    /// This method provides a reactive approach to fetch model data, returning a Combine publisher that emits an ``ModelResponse`` with details of available models.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    ///
    /// OllamaClient.models()
    ///     .sink(receiveCompletion: { completion in
    ///         // Handle completion
    ///     }, receiveValue: { modelResponse in
    ///         // Handle the received model response
    ///     })
    ///     .store(in: &cancellables)
    /// ```
    ///
    /// - Returns: A `AnyPublisher<ModelResponse, AFError>` that emits the list of available models.
    public func models() -> AnyPublisher<ModelResponse, AFError> {
        let request = AF.request(router.models).validate()
        
        return request
            .publishDecodable(type: ModelResponse.self, decoder: decoder).value()
            .eraseToAnyPublisher()
    }
    
    /// Asynchronously retrieves detailed information for a specific model from the Ollama API.
    ///
    /// This method accepts ``ModelInfoRequest`` and returns an ``ModelInfoResponse`` containing detailed information about the requested model.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let requestData = ModelInfoRequest(/* parameters */)
    /// let modelInfo = try await OllamaClient.modelInfo(data: requestData)
    /// ```
    ///
    /// - Parameter data: The ``ModelInfoRequest`` used to query the API for specific model information.
    /// - Returns: An ``ModelInfoResponse`` containing detailed information about the model.
    /// - Throws: An error if the request fails or the response can't be decoded.
    public func modelInfo(data: ModelInfoRequest) async throws -> ModelInfoResponse {
        let request = AF.request(router.modelInfo(data: data)).validate()
        let response = request.serializingDecodable(ModelInfoResponse.self, decoder: decoder)
        let value = try await response.value
        
        return value
    }
    
    /// Retrieves detailed information for a specific model from the Ollama API as a Combine publisher.
    ///
    /// This method provides a reactive approach to fetch detailed model information. It accepts ``ModelInfoRequest`` and returns a Combine publisher that emits an ``ModelInfoResponse`` upon successful retrieval.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let requestData = ModelInfoRequest(/* parameters */)
    ///
    /// OllamaClient.modelInfo(data: requestData)
    ///     .sink(receiveCompletion: { completion in
    ///         // Handle completion
    ///     }, receiveValue: { modelInfoResponse in
    ///         // Handle the received model info response
    ///     })
    ///     .store(in: &cancellables)
    /// ```
    ///
    /// - Parameter data: The ``ModelInfoRequest`` used to query the API for specific model information.
    /// - Returns: A `AnyPublisher<ModelInfoResponse, AFError>` that emits detailed information about the model.
    public func modelInfo(data: ModelInfoRequest) -> AnyPublisher<ModelInfoResponse, AFError> {
        let request = AF.request(router.modelInfo(data: data)).validate()
        
        return request
            .publishDecodable(type: ModelInfoResponse.self, decoder: decoder).value()
            .eraseToAnyPublisher()
    }
    
    /// Asynchronously requests the Ollama API to copy a model.
    ///
    /// This method sends a request to the Ollama API to copy a model based on the provided ``CopyModelRequest``.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let requestData = CopyModelRequest(/* parameters */)
    /// try await OllamaClient.copyModel(data: requestData)
    /// ```
    ///
    /// - Parameter data: The ``CopyModelRequest`` containing the details needed to copy the model.
    /// - Throws: An error if the request to copy the model fails.
    public func copyModel(data: CopyModelRequest) async throws -> Void {
        let request = AF.request(router.copyModel(data: data)).validate()
        _ = try await request.serializingData().response.result.get()
    }
    
    /// Requests the Ollama API to copy a model, returning the result as a Combine publisher.
    ///
    /// This method provides a reactive approach to request a model copy operation. It accepts ``CopyModelRequest`` and returns a Combine publisher that completes when the copy operation is finished.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let requestData = CopyModelRequest(/* parameters */)
    ///
    /// OllamaClient.copyModel(data: requestData)
    ///     .sink(receiveCompletion: { completion in
    ///         // Handle completion
    ///     }, receiveValue: {
    ///         // Handle successful completion of the copy operation
    ///     })
    ///     .store(in: &cancellables)
    /// ```
    ///
    /// - Parameter data: The ``CopyModelRequest`` used to request the model copy.
    /// - Returns: A `AnyPublisher<Void, Error>` that completes when the copy operation is done.
    public func copyModel(data: CopyModelRequest) -> AnyPublisher<Void, Error> {
        let request = AF.request(router.copyModel(data: data)).validate()
        
        return request.publishData()
            .tryMap { _ in Void() }
            .eraseToAnyPublisher()
    }
    
    /// Asynchronously requests the Ollama API to delete a specific model.
    ///
    /// This method sends a request to the Ollama API to delete a model based on the provided ``DeleteModelRequest``.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let requestData = DeleteModelRequest(/* parameters */)
    /// try await OllamaClient.deleteModel(data: requestData)
    /// ```
    ///
    /// - Parameter data: The ``DeleteModelRequest`` containing the details needed to delete the model.
    /// - Throws: An error if the request to delete the model fails.
    public func deleteModel(_ data: DeleteModelRequest) async throws -> Void {
        let request = AF.request(router.deleteModel(data: data)).validate()
        _ = try await request.serializingData().response.result.get()
    }
    
    /// Requests the Ollama API to delete a specific model, returning the result as a Combine publisher.
    ///
    /// This method provides a reactive approach to request a model deletion operation. It accepts ``DeleteModelRequest`` and returns a Combine publisher that completes when the deletion operation is finished.
    ///
    /// ```swift
    /// let OllamaClient = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
    /// let requestData = DeleteModelRequest(/* parameters */)
    ///
    /// OllamaClient.deleteModel(data: requestData)
    ///     .sink(receiveCompletion: { completion in
    ///         // Handle completion
    ///     }, receiveValue: {
    ///         // Handle successful completion of the deletion operation
    ///     })
    ///     .store(in: &cancellables)
    /// ```
    ///
    /// - Parameter data: The ``DeleteModelRequest`` used to request the model deletion.
    /// - Returns: A `AnyPublisher<Void, Error>` that completes when the deletion operation is done.
    public func deleteModel(_ data: DeleteModelRequest) -> AnyPublisher<Void, Error> {
        let request = AF.request(router.deleteModel(data: data)).validate()
        
        return request.publishData()
            .tryMap { _ in Void() }
            .eraseToAnyPublisher()
    }
    
    
    public func pullModel(_ data: PullModelRequest) -> AnyPublisher<PullModelResponse, AFError> {
        let subject = PassthroughSubject<PullModelResponse, AFError>()
        let request = AF.streamRequest(router.pullModel(data: data)).validate()
        
        request.responseStreamDecodable(of: PullModelResponse.self, using: decoder) { stream in
            switch stream.event {
            case .stream(let result):
                switch result {
                case .success(let response):
                    subject.send(response)
                case .failure(let error):
                    subject.send(completion: .failure(error))
                }
            case .complete(let completion):
                if completion.error != nil {
                    subject.send(completion: .failure(completion.error!))
                } else {
                    subject.send(completion: .finished)
                }
            }
        }
        
        return subject.eraseToAnyPublisher()
    }
    
    public func libraryModels() async throws -> [ModelInfo] {
        let html = await withCheckedContinuation { continuation in
            AF.request(router.libraryModels)
                .responseString { response in
                    continuation.resume(returning: response.value)
                }
        }
        guard let html else { return [] }
        return try SwiftSoup.parse(html)
            .getElementById("repo")?
            .select("h2")
            .compactMap{ try $0.text() }
            .compactMap{ ModelInfo(name: $0) } ?? []
    }
    
    public func undownloadedModels() async throws -> [ModelInfo] {
        let downloadedModels = try await models().models.map{ $0.name }
        let libraryModels = try await libraryModels()
        return libraryModels.filter{ !downloadedModels.contains( $0.name )  }
    }
}
