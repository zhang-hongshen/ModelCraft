//
//  OllamaService.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import Foundation
import Combine
import OllamaKit
import Alamofire

extension OllamaClient {
    static let shared = OllamaClient(baseURL: URL(string: "http://localhost:11434")!)
}

class OllamaService {
    static let shared = OllamaService()
    
    private let client = OllamaClient.shared
    
    func reachable() -> AnyPublisher<Bool, Never> {
        client.reachable()
    }
    
    func reachable() async -> Bool {
        await client.reachable()
    }
    
    func models() async throws -> [ModelInfo] {
        try await client.models().models
    }
    
    func pullModel(model: String) -> AnyPublisher<PullModelResponse, AFError> {
        client.pullModel(PullModelRequest(name: model))
    }
    
    func deleteModel(model: String) async throws {
        try await client.deleteModel(DeleteModelRequest(name: model))
    }
    
    func deleteModel(model: String) -> AnyPublisher<Void, Error> {
        client.deleteModel(DeleteModelRequest(name: model))
    }
    
    func chat(model: String, messages: [Message]) -> AnyPublisher<ChatResponse, AFError> {
        let msgs = messages.compactMap{ toChatRequestMessage($0) }
        return client.chat(ChatRequest(model: model,
                                messages: msgs))
        
    }
    
    func toChatRequestMessage(_ message: Message) -> OllamaKit.Message {
        let images = message.images.compactMap { data in
            data.base64EncodedString()
        }
        var role: OllamaKit.Message.Role {
            switch message.role {
            case .user: .user
            case .assistant: .assistant
            case .system: .system
            }
        }
        return OllamaKit.Message(role: role,
                                 content: message.content,
                                 images: images)
    }
    
}
