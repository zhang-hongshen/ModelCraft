//
//  ModelCraftApp.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData
import Combine
import TipKit

import OllamaKit

@main
struct ModelCraftApp: App {
    
    var sharedModelContainer: ModelContainer
    
    @State private var cancellables: Set<AnyCancellable> = []
    @State private var checkServerStatusTimer: Timer? = nil
    
    @State private var serverStatus: ServerStatus = .disconnected
    @State private var models: [ModelInfo] = []
    @State private var selectedModel: ModelInfo? = nil
    
    @AppStorage(UserDefaults.showInMenuBar)
    private var showInMenuBar: Bool = true
    
    init() {
        self.sharedModelContainer = {
            let schema = Schema([
                Message.self,
                Chat.self,
                ModelTask.self,
            ])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }()
        CachedDataActor.configure(modelContainer: sharedModelContainer)
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
        .windowResizability(.contentSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()
        }
    }
    
    func startOllamaServer() {
        DispatchQueue.global(qos: .background).async {
            // send user notification
            let executableName = "ollama"
            let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
            let process = Process()
            // run commana 'ollama serve' ollama is an exectuable, use system's ollama if exists or use the one in the bundle
            process.launchPath = "/usr/local/bin/ollama"
            process.arguments = ["serve"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                serverStatus = .launching
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    print(output)
                }
            } catch {
                print("Running command error, \(error)")
            }
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
    
}
