//
//  StorageView.swift
//  ModelCraft
//

import SwiftUI
import UniformTypeIdentifiers

struct StorageView: View {
    @Environment(UserSettings.self) private var userSettings

    @State private var isChoosingMediaDirectory = false
    @State private var isChoosingSkillDirectory = false
    @State private var selectedMediaDirectory: MediaDirectory?

    var body: some View {
        @Bindable var userSettings = userSettings

        Form {
            MediaStorageRows(
                imageDirectory: $userSettings.imageOutputDirectory,
                videoDirectory: $userSettings.videoOutputDirectory,
                audioDirectory: $userSettings.audioOutputDirectory,
                onChoose: { directory in
                    selectedMediaDirectory = directory
                    isChoosingMediaDirectory = true
                }
            )

            SkillDirectoriesRows(
                customDirectories: $userSettings.customSkillDirectories,
                onAdd: { isChoosingSkillDirectory = true }
            )
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingMediaDirectory, allowedContentTypes: [.folder]) { result in
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
        .fileImporter(isPresented: $isChoosingSkillDirectory, allowedContentTypes: [.folder]) { result in
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
    }
}

private struct SkillDirectoriesRows: View {
    @Binding var customDirectories: [URL]
    let onAdd: () -> Void

    var body: some View {
        Section("Skills") {
            SkillDirectoryRow(directory: UserDefaultSettings.skillDirectory, isDefault: true)

            ForEach(customDirectories, id: \.self) { directory in
                SkillDirectoryRow(directory: directory) {
                    customDirectories.removeAll { $0 == directory }
                }
            }

            Button(action: onAdd) {
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
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)

            Text(directory.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if isDefault {
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove Skill Directory")
            }
        }
        .padding(.vertical, 4)
    }
}

private enum MediaDirectory {
    case image
    case audio
    case video
}

private struct MediaStorageRows: View {
    @Binding var imageDirectory: URL
    @Binding var videoDirectory: URL
    @Binding var audioDirectory: URL
    let onChoose: (MediaDirectory) -> Void

    var body: some View {
        Group {
            MediaStorageLocationRow(
                title: "Images",
                directory: $imageDirectory,
                defaultDirectory: UserDefaultSettings.imageOutputDirectory
            ) {
                onChoose(.image)
            }
            MediaStorageLocationRow(
                title: "Video",
                directory: $videoDirectory,
                defaultDirectory: UserDefaultSettings.videoOutputDirectory
            ) {
                onChoose(.video)
            }
            MediaStorageLocationRow(
                title: "Audio",
                directory: $audioDirectory,
                defaultDirectory: UserDefaultSettings.audioOutputDirectory
            ) {
                onChoose(.audio)
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
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            FolderLocationButton(directory: directory, action: onChoose)
                .frame(maxWidth: 180)
            Button("Reset", systemImage: "arrow.counterclockwise") {
                directory = defaultDirectory
            }
            .labelStyle(.titleAndIcon)
            .disabled(directory.standardizedFileURL == defaultDirectory.standardizedFileURL)
        }
        .padding(.vertical, 3)
    }
}

private struct FolderLocationButton: View {
    let directory: URL
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.body)
                    .foregroundStyle(.blue)

                if directory.lastPathComponent.isEmpty {
                    Text("Folder")
                        .lineLimit(1)
                } else {
                    Text(directory.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose Folder")
        .help("Choose Folder")
    }
}

#Preview {
    StorageView()
        .environment(UserSettings())
}
