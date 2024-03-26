//
//  ModelCraftApp.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData
import Combine

@main
struct ModelCraftApp: App {
    
    var sharedModelContainer: ModelContainer
    
    @State private var serverStatus: ServerStatus = .disconnected
    @State private var cancellables: Set<AnyCancellable> = []
    @State private var modelTaskCancellation: Set<AnyCancellable> = []
    
    @Query var modelTasks: [ModelTask] = []
    @Environment(\.modelContext) private var modelContext
    
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
    }
    
    
    var body: some Scene {
        Group {
            WindowGroup {
                ContentView().applyUserSettings()
            }
#if os(macOS)
            Settings {
                SettingsView().applyUserSettings()
                    .frame(minWidth: 200, minHeight: 200)
            }
#endif
        }
        .modelContainer(sharedModelContainer)
        .environment(\.serverStatus, $serverStatus)
        .windowResizability(.contentSize)
        .backgroundTask(.urlSession("CheckServerStatus")) { urlSession in
            // check server status
            print("Checking server status...")
            checkServerStatus()
            
        }
        .backgroundTask(.urlSession("HandleModelTask")) { urlSession in
            // check server status
            print("Handling Model Task...")
            do {
                try handleModelTask()
            } catch {
                debugPrint(error.localizedDescription)
            }
            
        }
    }
    
    func startOllamaServer() {
        DispatchQueue.global(qos: .background).async {
            
            let executableName = "ollama"
            let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            let process = Process()
            // run commana 'ollama serve' ollama is an exectuable, use system's ollama if exists or use the one in the bundle
            process.launchPath = "/usr/local/bin/ollama"
            process.arguments = ["serve"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                serverStatus = .starting
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    print(output)
                }
            } catch {
                print("Error running command: \(error)")
            }
        }
    }
    
    private func checkServerStatus() {
        OllamaClient.shared.reachable()
            .sink { reachable in
                // modify environment server status
                self.serverStatus = reachable ? ServerStatus.connected : .disconnected
                print("updated server status...")
            }
            .store(in: &cancellables)
    }
    
    private func handleModelTask() throws {
        // write an multable loop
        for task in modelTasks {
            @Bindable var task = task
            guard task.status == .new else { continue }
            task.status = .running
            switch task.type {
            case .download: 
                OllamaClient.shared.pullModel(PullModelRequest(name: task.modelName))
                    .sink { completion in
                        switch completion {
                        case .finished: task.status = .completed
                        case .failure(let error): task.status = .failed
                            debugPrint("failure \(error.localizedDescription)")
                        }
                    } receiveValue: { response in
                        debugPrint("status \(response.status), completed \(response.completed ?? 0), total \(response.total ?? 0)")
                        if let completed = response.completed, let total = response.total {
                            task.value = Double(completed)
                            task.total = Double(total)
                        }
                    }.store(in: &modelTaskCancellation)
            case .delete: 
                OllamaClient.shared.deleteModel(DeleteModelRequest(name: task.modelName))
                    .sink { completion in
                        switch completion {
                        case .finished: task.status = .completed
                        case .failure(_): task.status = .failed
                        }
                    } receiveValue: {_ in }
                    .store(in: &modelTaskCancellation)
            }
        }
        try modelContext.delete(model: ModelTask.self,
                                where: ModelTask.predicateByStatus(.completed))
        try modelContext.save()
    }
    
}
