//
//  ModelCraftApp.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import SwiftUI
import SwiftData
import AVFoundation

import MLX

@main
struct ModelCraftApp: App {
    
    @State private var modelTaskTimer: Timer? = nil
    
    @Environment(\.openWindow) private var openWindow
    
    private let globalStore = GlobalStore()
    private let userSettings = UserSettings()
    private let speechManager = SpeechManager()
    private let sttService = STTService()
    
    init() {}
    
    var body: some Scene {
        Group {
            WindowGroup {
                ContentView()
                    .background(.ultraThinMaterial)
                    .applyUserSettings()
                    .task {
                        modelTaskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
                            guard timer.isValid else { return }
                            try? self.handleModelTask()
                        }
                        await SkillManager.shared.loadSkills()
                    }
            }.commands {
                CommandGroup(after: .help) {
                    Button("Acknowledgments") {
                        openWindow(id: "acknowledgments")
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
        .modelContainer(.shared)
        .environment(speechManager)
        .environment(globalStore)
        .environment(userSettings)
        .environment(sttService)
        .windowResizability(.contentSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()
        }
    }
    
}

extension ModelCraftApp {
    
    private func handleModelTask() throws {
        let descriptor = FetchDescriptor<ModelTask>(
            predicate: ModelTask.predicateUnCompletedTask
        )

        let modelTasks = try ModelContainer.shared.mainContext.fetch(descriptor)
        for task in modelTasks.filter({ $0.status == .new}) {
            switch task.type {
            case .download: handleDownloadTask(task)
            case .delete: handleDeleteTask(task)
            }
        }
    }
    
    func handleDownloadTask(_ task: ModelTask) {
        print("Downloading \(task.modelID)")
        
        task.status = .running
        let downloadTask = Task {
            defer {
                globalStore.runningTasks.removeValue(forKey: task.modelID)
            }
            do {
                let localModel = LocalModel(id: task.modelID, size: task.totalUnitCount ?? 0)
                for try await progress in ModelService.shared.downloadModel(modelID: task.modelID) {
                    task.completedUnitCount = progress.completedUnitCount
                    task.totalUnitCount = progress.totalUnitCount
                    task.fractionCompleted = progress.fractionCompleted
                }
                try Task.checkCancellation()
                task.status = .completed
                
                ModelContainer.shared.mainContext.delete(task)
                ModelContainer.shared.mainContext.persist(localModel)
                print("\(localModel.id) downloaded")
                
            } catch is CancellationError {
                task.status = .stopped
            } catch {
                task.status = .failed
            }
        }
        globalStore.runningTasks[task.modelID] = downloadTask
    }
    
    func handleDeleteTask(_ task: ModelTask) {
        print("Deleting \(task.modelID)")
        task.status = .running
        let deleteTask = Task {
            defer {
                globalStore.runningTasks.removeValue(forKey: task.modelID)
            }
            do {
                try ModelService.shared.deleteModel(modelID: task.modelID)
                task.status = .completed
                ModelContainer.shared.mainContext.delete(task)
            } catch is CancellationError {
                task.status = .stopped
            } catch {
                task.status = .failed
            }
        }
        globalStore.runningTasks[task.modelID] = deleteTask
        
    }
    
}
