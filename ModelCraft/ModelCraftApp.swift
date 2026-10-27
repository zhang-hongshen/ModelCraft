//
//  ModelCraftApp.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/24.
//

import SwiftUI
import SwiftData
import AVFoundation

import MLX
import Hub

@main
struct ModelCraftApp: App {
    
    @State private var modelTaskTimer: Timer? = nil
    
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    
    private let globalStore: GlobalStore
    @State private var localModelStore: LocalModelStore
    @State private var scheduler: Scheduler
    
    init() {
        _ = NetworkMonitor.shared
        URL.moveLegacyAppSupportDirectory()
        try? FileManager.default.removeItem(at: Message.draftDirectory)
        let globalStore = GlobalStore.shared
        let localModelStore = LocalModelStore()
        self.globalStore = globalStore
        _localModelStore = State(initialValue: localModelStore)
        _scheduler = State(initialValue: Scheduler(
            localModelStore: localModelStore, globalStore: globalStore))
    }
    
    var body: some Scene {
        Group {
            WindowGroup {
                ContentView()
                    .background(.ultraThinMaterial)
                    .tint(.accent)
                    .applyUserSettings()
                    .task {
                        HubApi.moveSystemModels(ids: ToolDefinition.modelIDs)
                        localModelStore.reload()
                        modelTaskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
                            guard timer.isValid else { return }
                            try? self.handleModelTask()
                        }
                        SkillManager.shared.loadSkills()
                        scheduler.start()
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
                AppMenuCommands(globalStore: globalStore)
            }
            Settings {
                SettingsView().background(.ultraThinMaterial)
                    .tint(.accent)
                    .applyUserSettings()
                    .frame(minWidth: 560, idealWidth: 640, maxWidth: 760, minHeight: 200)
            }
        }
        .modelContainer(.shared)
        .environment(SpeechManager())
        .environment(globalStore)
        .environment(localModelStore)
        .environment(scheduler)
        .environment(UserSettings.shared)
        .environment(STTService())
        .environment(TTSService())
        .windowResizability(.contentSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()
        }
    }
    
}

/// The sidebar's actions in the menu bar: File ▸ New Chat and New Project…, View ▸ sections, and the Chat menu.
private struct AppMenuCommands: Commands {

    let globalStore: GlobalStore

    @FocusedValue(\.sidebarCommands) private var sidebarCommands

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Chat") {
                globalStore.startNewChat()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Project…") {
                sidebarCommands?.newProject()
            }
            .disabled(sidebarCommands == nil)
        }
        CommandGroup(before: .sidebar) {
            tabButton("Model Store", tab: .modelStore, key: "1")
            tabButton("Downloaded Models", tab: .downloadedModels, key: "2")
            tabButton("Connectors", tab: .connectors, key: "3")
            tabButton("Scheduled Tasks", tab: .schedules, key: "4")
            Divider()
        }
        CommandMenu("Chat") {
            Button("Rename Chat…") {
                sidebarCommands?.renameChat?()
            }
            .disabled(sidebarCommands?.renameChat == nil)
            Button("Delete Chat") {
                sidebarCommands?.deleteChat?()
            }
            .disabled(sidebarCommands?.deleteChat == nil)
        }
    }

    private func tabButton(_ title: LocalizedStringKey, tab: AppNavigationTab, key: KeyEquivalent) -> some View {
        Button(title) {
            globalStore.currentTab = tab
        }
        .keyboardShortcut(key, modifiers: .command)
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
                for try await progress in ModelService.downloadModel(modelID: task.modelID) {
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
                try ModelService.deleteModel(modelID: task.modelID)
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
