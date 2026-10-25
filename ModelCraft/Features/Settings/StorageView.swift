//
//  StorageView.swift
//  ModelCraft
//

import SwiftUI
import UniformTypeIdentifiers

struct StorageView: View {
    @Environment(UserSettings.self) private var userSettings

    @State private var isChoosingSkillDirectory = false

    var body: some View {
        @Bindable var userSettings = userSettings

        Form {
            SkillDirectoriesRows(
                customDirectories: $userSettings.customSkillDirectories,
                onAdd: { isChoosingSkillDirectory = true }
            )
        }
        .formStyle(.grouped)
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

#Preview {
    StorageView()
        .environment(UserSettings())
}
