//
//  ProjectEdition.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/24.
//

import SwiftUI
import SwiftData

struct ProjectEdition: View {
    
    @Bindable var project: Project
    @State private var folderImporterPresented = false
    @State private var resourceImporterPresented = false
    @State private var selectedFiles: Set<URL> = []
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name")
                        .fontWeight(.medium)
                    TextField("Project Documentation", text: $project.title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Working Folder")
                        .fontWeight(.medium)
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        if let workingDirectory = project.workingDirectory {
                            Text(workingDirectory.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(workingDirectory.path)
                        } else {
                            Text("No Folder")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Choose Folder") {
                            folderImporterPresented = true
                        }
                        if project.workingDirectory != nil {
                            Button("Remove Folder", systemImage: "xmark") {
                                project.workingDirectory = nil
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Remove Folder")
                        }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 4)
                }

                ProjectReferenceFiles(
                    resources: project.resources,
                    selection: $selectedFiles,
                    addFiles: { resourceImporterPresented = true },
                    removeFiles: {
                        project.removeResources(selectedFiles)
                        selectedFiles.removeAll()
                    }
                )

            }
            .padding(20)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .frame(minWidth: 480, idealWidth: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $folderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result {
                project.workingDirectory = urls.first?.standardizedFileURL
            }
        }
        .fileImporter(
            isPresented: $resourceImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                project.addResources(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addDroppedItems(urls)
            return true
        }
    }
}

private struct ProjectReferenceFiles: View {
    let resources: [URL]
    @Binding var selection: Set<URL>
    let addFiles: () -> Void
    let removeFiles: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Reference Files")
                    .fontWeight(.medium)
                Text("\(resources.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Add Files", systemImage: "plus", action: addFiles)
                Button(role: .destructive, action: removeFiles) {
                    Label("Remove", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .disabled(selection.isEmpty)
            }
            .controlSize(.small)
            .padding(12)

            Divider()

            Group {
                if resources.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.badge.plus")
                            .font(.title2)
                            .accessibilityHidden(true)
                        Text("No reference files added yet")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                } else {
                    List(resources, id: \.self, selection: $selection) { url in
                        HStack(spacing: 8) {
                            FileThumbnail(url: url)
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help(url.path)
                        .tag(url)
                    }
                    .listStyle(.inset)
                    .frame(height: 160)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

extension ProjectEdition {
    
    func save() {
        dismiss()
        modelContext.persist(project)
    }

    private func addDroppedItems(_ urls: [URL]) {
        var resources: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                project.workingDirectory = url.standardizedFileURL
            } else {
                resources.append(url)
            }
        }
        project.addResources(resources)
    }
    
}

#if DEBUG
#Preview {
    ProjectEdition(project: .preview)
}
#endif
