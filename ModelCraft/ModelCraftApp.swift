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
    @Environment(\.scenePhase) private var scenePhase
    
    private let globalStore = GlobalStore()
    @State private var localModelStore = LocalModelStore()
    
    init() {}
    
    var body: some Scene {
        Group {
            WindowGroup {
                ContentView()
                    .background(.ultraThinMaterial)
                    .applyUserSettings()
                    .task {
                        localModelStore.reload()
                        modelTaskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
                            guard timer.isValid else { return }
                            try? self.handleModelTask()
                        }
                        await SkillManager.shared.loadSkills()
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        guard newPhase == .active else { return }
                        localModelStore.reload()
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
        .environment(SpeechManager())
        .environment(globalStore)
        .environment(localModelStore)
        .environment(UserSettings())
        .environment(STTService())
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
        let tasks = try ModelContainer.shared.mainContext.fetch(ModelTask.fetchByStatus(.new))
        for task in tasks {
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
                for try await progress in ModelService.shared.downloadModel(modelID: task.modelID) {
                    task.completedUnitCount = progress.completedUnitCount
                    task.totalUnitCount = progress.totalUnitCount
                    task.fractionCompleted = progress.fractionCompleted
                }
                try Task.checkCancellation()
                localModelStore.reload()
                task.status = .completed
                
                ModelContainer.shared.mainContext.delete(task)
                print("\(task.modelID) downloaded")
                
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
                localModelStore.reload()
                if globalStore.selectedModel?.id == task.modelID {
                    globalStore.selectedModel = nil
                }
            } catch is CancellationError {
                task.status = .stopped
            } catch {
                task.status = .failed
            }
        }
        globalStore.runningTasks[task.modelID] = deleteTask
        
    }
    
}
