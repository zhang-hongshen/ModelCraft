//
//  ModelCraftApp.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData
import Combine
import AVFoundation
import TipKit

import OllamaKit
import Sparkle

@main
struct ModelCraftApp: App {
    
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
        Message.self,
        Chat.self,
        ModelTask.self,
        KnowledgeBase.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    @State private var cancellables: Set<AnyCancellable> = []
    @State private var checkServerStatusTimer: Timer? = nil
    
    @State private var serverStatus: ServerStatus = .disconnected
    @State private var models: [ModelInfo] = []
    @State private var selectedModel: ModelInfo? = nil
    
    @AppStorage(UserDefaults.showInMenuBar)
    private var showInMenuBar: Bool = true
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    private let updaterController: SPUStandardUpdaterController
    
    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)
        startOllamaServer()
        try? Tips.resetDatastore()
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault)
        ])
    }
    
    // write an background task to download model
    
    var body: some Scene {
        Group {
            WindowGroup {
                ContentView()
                    .background(.ultraThinMaterial)
                    .applyUserSettings()
                    .task {
                        checkServerStatusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
                            guard timer.isValid else { return }
                            checkServerStatus()
                            Task.detached {
                                models = try await OllamaService.shared.models()
                                if let model = selectedModel {
                                    if !models.contains(model) {
                                        selectedModel = models.first
                                    }
                                } else {
                                    selectedModel = models.first
                                }
                            }
                        }
                    }
            }
#if os(macOS)
            Settings {
                SettingsView().background(.ultraThinMaterial)
                    .applyUserSettings()
                    .frame(minWidth: 200, minHeight: 200)
            }
            
            MenuBarExtra(isInserted: $showInMenuBar) {
                ServerStatusView()
                Button("Open \(Bundle.main.applicationName)") {
                    // show the main window
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
                Divider()
                Button("Quit") {
                    NSApp.terminate(nil)
                }.keyboardShortcut("q")
            } label: {
                Image(systemName: "wrench.adjustable")
            }
#endif
        }
        .modelContainer(sharedModelContainer)
        .environment(\.serverStatus, $serverStatus)
        .environment(\.downaloadedModels, models)
        .environment(\.selectedModel, $selectedModel)
        .environment(\.speechSynthesizer, speechSynthesizer)
        .windowResizability(.contentSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
    
    func startOllamaServer() {
        Task {
            serverStatus = .launching
            try shell("base64 --version")
            try shell("ollama serve")
            try shell("env")
            let db = try FileManager.default.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            try shell("chroma run --path \(db)")
            
        }
    }
    
    private func checkServerStatus() {
        OllamaService.shared.reachable()
            .sink { reachable in
                // modify environment server status
                self.serverStatus = reachable ? ServerStatus.connected : .disconnected
                print("Ollama server status, \(serverStatus.localizedDescription)")
            }
            .store(in: &cancellables)
    }
    
    func shell(_ command: String) throws {
        let process = Process()
        process.arguments = ["-c",command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = nil
        // get user current shell, eg: bash , zsh
        if let shellPath = ProcessInfo.processInfo.environment["SHELL"] {
            process.executableURL = URL(filePath: shellPath)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            process.environment = ["PATH": "/opt/homebrew/bin:/opt/homebrew/anaconda3/envs/chroma-demo/bin:"+path]
        }
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            print(output)
        }
    }
}
