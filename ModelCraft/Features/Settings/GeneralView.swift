//
//  GeneralView.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import SwiftUI
import UniformTypeIdentifiers

struct GeneralView: View {
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(LocalModelStore.self) private var localModelStore
    @Environment(UserSettings.self) private var userSettings

    @State private var isChoosingModelDirectory = false
    @State private var isMovingModels = false
    @State private var moveError: String?
    
    var body: some View {
        
        @Bindable var userSettings = userSettings
        
        Form {
            Picker("Appearance", selection: $userSettings.appearance) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
            Picker("Language", selection: $userSettings.language) {
                ForEach(Bundle.main.localizations, id:\.self) { languageCode in
                    if let language = Locale(identifier: languageCode)
                        .localizedString(forLanguageCode: languageCode) {
                        Text(verbatim: language).tag(languageCode)
                    }
                }
            }

            Section("Model Storage") {
                LabeledContent("Download Location") {
                    HStack {
                        Text(userSettings.modelDownloadBaseDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Button {
                            isChoosingModelDirectory = true
                        } label: {
                            Label("Choose Folder…", systemImage: "folder")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(isMovingModels || !globalStore.runningTasks.isEmpty)

                        Button {
                            changeModelDownloadDirectory(to: UserDefaultSettings.modelDownloadBaseDirectory)
                        } label: {
                            Label("Restore Default", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(
                            isMovingModels
                            || !globalStore.runningTasks.isEmpty
                            || userSettings.modelDownloadBaseDirectory.standardizedFileURL
                                == UserDefaultSettings.modelDownloadBaseDirectory.standardizedFileURL
                        )

                        if isMovingModels {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }

        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $isChoosingModelDirectory,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else { return }
            changeModelDownloadDirectory(to: url)
        }
        .alert("Unable to Move Models", isPresented: .init(
            get: { moveError != nil },
            set: { if !$0 { moveError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(moveError ?? "")
        }
    }

    private func changeModelDownloadDirectory(to newDownloadBase: URL) {
        isMovingModels = true
        let oldDownloadBase = userSettings.modelDownloadBaseDirectory

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fileManager = FileManager.default
                    let oldModelsDirectory = oldDownloadBase.appending(path: "models")
                    let newModelsDirectory = newDownloadBase.appending(path: "models")

                    try fileManager.createDirectoryIfNotExists(at: newDownloadBase)

                    if fileManager.fileExists(at: oldModelsDirectory) {
                        guard !fileManager.fileExists(at: newModelsDirectory) else {
                            throw RuntimeError(String(
                                localized: "The selected location already contains a models folder."
                            ))
                        }
                        try fileManager.moveDirectory(
                            at: oldModelsDirectory,
                            to: newModelsDirectory
                        )
                    }
                }.value
                userSettings.modelDownloadBaseDirectory = newDownloadBase.standardizedFileURL
                localModelStore.reload()
            } catch {
                moveError = error.localizedDescription
            }
            isMovingModels = false
        }
    }
}

#Preview {
    GeneralView()
        .environment(GlobalStore())
        .environment(LocalModelStore())
        .environment(UserSettings())
}
