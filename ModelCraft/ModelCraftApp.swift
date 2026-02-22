//
//  ModelCraftApp.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import SwiftUI
import SwiftData
import AVFoundation

import OllamaKit

@main
struct ModelCraftApp: App {
    
    @State private var models: [ModelInfo] = []
    @State private var checkServerStatusTaskTimer: Timer? = nil
    @State private var fetchDownloadedModelsTaskTimer: Timer? = nil
    
    private let globalStore = GlobalStore()
    private let userSettings = UserSettings()
    private let speechManager = SpeechManager()
    
    @Environment(\.openWindow) private var openWindow
    
    init() {}
    
    var body: some Scene {
        Group {
            WindowGroup {
                ContentView()
                    .background(.ultraThinMaterial)
                    .applyUserSettings()
                    .task {
                        checkServerStatusTaskTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
                            guard timer.isValid else { return }
                            Task {
                                await checkServerStatus()
                            }
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
        .modelContainer(ModelContainer.shared)
        .environment(\.downaloadedModels, models)
        .environment(speechManager)
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
    
    private func checkServerStatus() async {
        globalStore.serverStatus = await OllamaService.shared.reachable() ? .connected : .disconnected
#if os(macOS)
        if globalStore.serverStatus == .disconnected {
            OllamaService.shared.start()
        }
#endif
    }
    
    
}
