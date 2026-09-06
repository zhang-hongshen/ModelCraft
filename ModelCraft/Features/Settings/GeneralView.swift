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
    @State private var isChoosingMediaDirectory = false
    @State private var isChoosingSkillDirectory = false
    @State private var selectedMediaDirectory: MediaDirectory?
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

            SkillDirectoriesSection(
                customDirectories: $userSettings.customSkillDirectories
            ) {
                isChoosingSkillDirectory = true
            }

            MediaStorageSection(
                imageDirectory: $userSettings.imageOutputDirectory,
                audioDirectory: $userSettings.audioOutputDirectory,
                videoDirectory: $userSettings.videoOutputDirectory
            ) { directory in
                selectedMediaDirectory = directory
                isChoosingMediaDirectory = true
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
        .fileImporter(
            isPresented: $isChoosingMediaDirectory,
            allowedContentTypes: [.folder]
        ) { result in
            defer { selectedMediaDirectory = nil }
            guard case .success(let url) = result,
                  let selectedMediaDirectory else { return }
            let directory = url.standardizedFileURL
            switch selectedMediaDirectory {
            case .image:
                userSettings.imageOutputDirectory = directory
            case .audio:
                userSettings.audioOutputDirectory = directory
            case .video:
                userSettings.videoOutputDirectory = directory
            }
        }
        .fileImporter(
            isPresented: $isChoosingSkillDirectory,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else { return }
            let directory = url.standardizedFileURL
            guard directory != UserDefaultSettings.skillDirectory.standardizedFileURL,
                  !userSettings.customSkillDirectories.contains(directory) else {
                return
            }
            userSettings.customSkillDirectories.append(directory)
        }
        .onChange(of: userSettings.customSkillDirectories) {
            SkillManager.shared.loadSkills()
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

private struct SkillDirectoriesSection: View {
    @Binding var customDirectories: [URL]
    let onChoose: () -> Void

    var body: some View {
        Section("Skill Directories") {
            SkillDirectoryRow(
                directory: UserDefaultSettings.skillDirectory,
                isDefault: true
            )

            ForEach(customDirectories, id: \.self) { directory in
                SkillDirectoryRow(directory: directory) {
                    customDirectories.removeAll { $0 == directory }
                }
            }

            Button(action: onChoose) {
                Label("Add Skill Directory…", systemImage: "plus")
            }
        }
    }
}

private struct SkillDirectoryRow: View {
    let directory: URL
    var isDefault = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            Text(directory.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            if isDefault {
                Text("Default")
                    .foregroundStyle(.secondary)
            } else if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Skill Directory", systemImage: "minus.circle")
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}

private enum MediaDirectory {
    case image
    case audio
    case video
}

private struct MediaStorageSection: View {
    @Binding var imageDirectory: URL
    @Binding var audioDirectory: URL
    @Binding var videoDirectory: URL
    let onChoose: (MediaDirectory) -> Void

    var body: some View {
        Section("Media Storage") {
            MediaStorageLocationRow(
                title: "Images",
                directory: $imageDirectory,
                defaultDirectory: UserDefaultSettings.imageOutputDirectory
            ) {
                onChoose(.image)
            }
            MediaStorageLocationRow(
                title: "Audio",
                directory: $audioDirectory,
                defaultDirectory: UserDefaultSettings.audioOutputDirectory
            ) {
                onChoose(.audio)
            }
            MediaStorageLocationRow(
                title: "Video",
                directory: $videoDirectory,
                defaultDirectory: UserDefaultSettings.videoOutputDirectory
            ) {
                onChoose(.video)
            }
        }
    }
}

private struct MediaStorageLocationRow: View {
    let title: LocalizedStringKey
    @Binding var directory: URL
    let defaultDirectory: URL
    let onChoose: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(directory.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button(action: onChoose) {
                    Label("Choose Folder…", systemImage: "folder")
                        .labelStyle(.iconOnly)
                }

                Button {
                    directory = defaultDirectory
                } label: {
                    Label("Restore Default", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(directory.standardizedFileURL == defaultDirectory.standardizedFileURL)
            }
        }
    }
}

#Preview {
    GeneralView()
        .environment(GlobalStore())
        .environment(LocalModelStore())
        .environment(UserSettings())
}
