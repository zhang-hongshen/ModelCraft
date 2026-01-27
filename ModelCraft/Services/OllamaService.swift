//
//  OllamaService.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import Foundation
import OllamaKit
import AppKit

class OllamaService {
    
    static let shared = OllamaService()
    
    private let client = OllamaClient(baseURL: URL(string: ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://localhost:11434")!)
    
    private var observers: [Any] = []
    
    init() {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
    
        let terminateObserver = center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main) { _ in
            print("willTerminateNotification")
            self.stop()
        }
        let sleepObserver = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main) { _ in
            self.start()
        }
        let wakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main) { _ in
            self.stop()
        }
        #endif

        observers = [terminateObserver, sleepObserver, wakeObserver]
    }
    
    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    
#if os(macOS)
    func start() {
        Task(priority: .background) {
            try CommandExecutor.run(Bundle.main.url(forAuxiliaryExecutable: "ollama"), arguments: ["serve"]) { (_, _) in }
        }
    }
    
    func stop() {
        Task(priority: .background) {
            try CommandExecutor.run(Bundle.main.url(forAuxiliaryExecutable: "ollama"), arguments: ["stop"]) { (_, _) in }
        }
    }
#endif
    
    func reachable() async -> Bool {
        await client.reachable()
    }
    
    func models() async throws -> [ModelInfo] {
        try await client.models().models
    }
    
    func pullModel(model: String) -> AsyncThrowingStream<PullModelResponse, Error> {
        client.pullModel(PullModelRequest(model: model))
    }
    
    func deleteModel(model: String) async throws {
        try await client.deleteModel(DeleteModelRequest(model: model))
    }
    
    func chat(model: String, messages: [OllamaKit.Message]) -> AsyncThrowingStream<ChatResponse, Error> {
        return client.chat(ChatRequest(model: model,
                                messages: messages), timeout: 120)
    }
    
    func chat(model: String, messages: [OllamaKit.Message]) async throws -> ChatResponse {
        return try await client.chat(ChatRequest(model: model,
                                                 messages: messages), timeout: 120)
    }
    
    func modelTags(_ model: String) async throws -> [ModelInfo] {
        return try await client.modelTags(model)
    }
    
    func libraryModels() async throws -> [ModelInfo] {
        return try await client.libraryModels()
    }
    
}


extension OllamaService {
    
    static func toChatRequestMessage(_ message: Message) -> OllamaKit.Message {
        let images = message.images.compactMap { data in
            data.base64EncodedString()
        }
        var role: OllamaKit.Message.Role {
            switch message.role {
            case .user: .user
            case .assistant: .assistant
            case .system: .system
            case .tool: .tool
            }
        }
        return OllamaKit.Message(role: role,
                                 content: message.content,
                                 images: images)
    }
}
