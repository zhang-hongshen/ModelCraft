//
//  ModelCraftApp.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData
import AVFoundation
import Combine
import TipKit

import OllamaKit

@main
struct ModelCraftApp: App {
    
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Message.self, Chat.self, ModelTask.self,
            KnowledgeBase.self, Prompt.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    @State private var cancellables: Set<AnyCancellable> = []
    @State private var backgroudTaskTimer: Timer? = nil
    @State private var serverStatus: ServerStatus = .disconnected
    @State private var models: [ModelInfo] = []
    @State private var selectedModel: ModelInfo? = nil
    @State private var errorWrapper: ErrorWrapper? = nil
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    init() {
        startOllamaServer()
    }
    
    var body: some Scene {
        Group {
            WindowGroup {
                ContentView()
                    .background(.ultraThinMaterial)
                    .applyUserSettings()
                    .alert(errorWrapper?.error.localizedDescription ?? "",
                           isPresented: Binding(
                            get: { errorWrapper != nil },
                            set: { _ in }),
                           presenting: errorWrapper){ _ in
                        Button("Ok") {
                            errorWrapper = nil
                        }
                    } message: { errorWrapper in
                        Text(errorWrapper.guidance)
                    }
                    .task {
                        LoopTask()
                        backgroudTaskTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
                            guard timer.isValid else { return }
                            LoopTask()
                        }
                    }
            }
#if os(macOS)
            Settings {
                SettingsView().background(.ultraThinMaterial)
                    .applyUserSettings()
                    .frame(minWidth: 200, minHeight: 200)
            }
#endif
        }
        .modelContainer(sharedModelContainer)
        .environment(\.serverStatus, $serverStatus)
        .environment(\.downaloadedModels, models)
        .environment(\.selectedModel, $selectedModel)
        .environment(\.speechSynthesizer, speechSynthesizer)
        .environment(\.errorWrapper, $errorWrapper)
        .windowResizability(.contentSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()
        }
    }
    
}

extension ModelCraftApp {
    func LoopTask() {
        checkServerStatus()
        fetchLocalModels()
    }
    
    func fetchLocalModels() {
        Task.detached {
            models = try await OllamaService.shared.models()
            if let model = await selectedModel {
                if !models.contains(model) {
                    selectedModel = models.first
                }
            } else {
                selectedModel = models.first
            }
        }
    }
    
    func startOllamaServer() {
        Task {
            serverStatus = .launching
            do {
                let process = Process()
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = nil
                
                process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "ollama")
                process.arguments = ["serve"]
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    print(output)
                }
            } catch {
                print("Failed to start Ollama server: \(error)")
            }
        }
    }
    
    private func checkServerStatus() {
        OllamaService.shared.reachable()
            .sink { reachable in
                // modify environment server status
                self.serverStatus = reachable ? ServerStatus.connected : .disconnected
                print("Ollama server status, \(serverStatus.localizedDescription)")
                if serverStatus == .disconnected {
                    startOllamaServer()
                }
            }
            .store(in: &cancellables)
    }
    
    func shell(_ command: String) throws {
        let process = Process()
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = nil
        // get user current shell, eg: bash , zsh
        process.arguments = ["-c", command]
        if let shellPath = ProcessInfo.processInfo.environment["SHELL"] {
            process.executableURL = URL(filePath: shellPath)
        }
        
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            process.environment = ["PATH": """
                                   /usr/local/bin:
                                   /opt/homebrew/bin:
                                   /opt/homebrew/bin:
                                   /opt/homebrew/sbin:
                                   """+path]
        }
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            print(output)
        }
    }
}
