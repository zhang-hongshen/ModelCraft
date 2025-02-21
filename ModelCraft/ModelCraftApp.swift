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
    @State private var models: [ModelInfo] = []
    private let globalStore = GlobalStore()
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    @State private var modelTaskTimer: Timer? = nil
    @State private var modelTaskCancellables: Set<AnyCancellable> = []
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
                    .alert(globalStore.errorWrapper?.error.localizedDescription ?? "",
                           isPresented: Binding(
                            get: { globalStore.errorWrapper != nil },
                            set: { _ in }),
                           presenting: globalStore.errorWrapper){ _ in
                        Button("Ok") {
                            globalStore.errorWrapper = nil
                        }
                    } message: { errorWrapper in
                        Text(errorWrapper.guidance)
                    }
                    .task {
                        await LoopTask()
                        backgroudTaskTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
                            guard timer.isValid else { return }
                            Task {
                                await LoopTask()
                            }
                        }
                    }
            }.commands {
                CommandGroup(after: .help) {
                    Button("Acknowledgments") {
                        openWindow(id: "acknowledgment")
                    }
                }
            }
            
            WindowGroup(id: "acknowledgment") {
                AcknowledgmentView()
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
        .environmentObject(globalStore)
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
#endif
    
    func LoopTask() async {
        checkServerStatus()
        await fetchLocalModels()
    }
    
    func fetchLocalModels() async {
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
