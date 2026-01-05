//
//  ModelCraftApp.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
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
            KnowledgeBase.self, Prompt.self, Conversation.self
        ])
#if DEBUG
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
#else
        let modelConfiguration = ModelConfiguration(schema: schema)
#endif

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    @State private var models: [ModelInfo] = []
    @State private var cancellables: Set<AnyCancellable> = []
    @State private var checkServerStatusTaskTimer: Timer? = nil
    @State private var fetchDownloadedModelsTaskTimer: Timer? = nil
    
    private let globalStore = GlobalStore()
    private let userSettings = UserSettings()
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    @Environment(\.openWindow) private var openWindow
    
    init() {
#if os(macOS)
        startOllamaServer()
#endif
    }
    
    var body: some Scene {
        Group {
            WindowGroup {
                ContentView()
                    .background(.ultraThinMaterial)
                    .applyUserSettings()
                    .alert(globalStore.errorWrapper?.localizedDescription ?? "",
                           isPresented: Binding(
                            get: { globalStore.errorWrapper != nil },
                            set: { _ in }),
                           presenting: globalStore.errorWrapper){ _ in
                        Button("OK") {
                            globalStore.errorWrapper = nil
                        }
                    } message: { errorWrapper in
                        Text(errorWrapper.recoverySuggestion)
                    }
                    .task {
                        checkServerStatusTaskTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
                            guard timer.isValid else { return }
                            checkServerStatus()
                        }
                        fetchDownloadedModelsTaskTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
                            guard timer.isValid else { return }
                            Task {
                                await fetchDownloadedModels()
                            }
                        }
                    }
            }.commands {
                CommandGroup(after: .help) {
                    Button("Acknowledgments") {
                        openWindow(id: "acknowledgments")
                    }
                }
            }
            
            WindowGroup(id: "acknowledgments") {
                AcknowledgmentView().applyUserSettings()
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
        .environment(\.downaloadedModels, models)
        .environment(\.speechSynthesizer, speechSynthesizer)
        .environment(globalStore)
        .environment(userSettings)
        .windowResizability(.contentSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()
        }
    }
    
}

extension ModelCraftApp {
    
#if os(macOS)
    func startOllamaServer() {
        globalStore.serverStatus = .launching
        DispatchQueue.global(qos: .background).async {
            do {
                let process = Process()
                let pipe = Pipe()
                
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = nil
                process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "ollama")
                process.arguments = ["serve"]
                
                try process.run()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let output = String(data: data, encoding: .utf8) {
                        print(output)
                    }
                }
                process.waitUntilExit()
            } catch {
                print("Failed to start Ollama server: \(error)")
            }
        }
    }
    func stopOllamaServer() {
        DispatchQueue.global(qos: .background).async {
            do {
                let process = Process()
                let pipe = Pipe()
                
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = nil
                process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "ollama")
                process.arguments = ["stop"]
                
                try process.run()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let output = String(data: data, encoding: .utf8) {
                        print(output)
                    }
                }
                process.waitUntilExit()
            } catch {
                print("Failed to stop Ollama server: \(error)")
            }
        }
    }
#endif
    
    func fetchDownloadedModels() async {
        do {
            models = try await OllamaService.shared.models()
            if globalStore.selectedModel == nil || !models.map({ $0.name }).contains(globalStore.selectedModel!) {
                globalStore.selectedModel = models.first?.name
            }
        } catch {
            print("Failed to fetch models: \(error)")
        }
    }
    
    private func checkServerStatus() {
        OllamaService.shared.reachable()
            .sink { reachable in
                // modify environment server status
                globalStore.serverStatus = reachable ? .connected : .disconnected
#if os(macOS)
                if globalStore.serverStatus == .disconnected {
                    startOllamaServer()
                }
#endif
            }
            .store(in: &cancellables)
    }
    
    
}
