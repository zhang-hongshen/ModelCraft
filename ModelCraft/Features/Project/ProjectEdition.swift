//
//  ProjectEdition.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/2024.
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
        VStack(alignment: .leading, spacing: 20) {
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontWeight(.medium)
                
                TextField("Project Documentation", text: $project.title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(Layout.padding)
                    .background(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            }
            
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Working Folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontWeight(.medium)

                HStack {
                    if let workingDirectory = project.workingDirectory {
                        Label(workingDirectory.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Label("No Folder", systemImage: "folder")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Choose Folder") {
                        folderImporterPresented = true
                    }
                    .controlSize(.small)

                    if project.workingDirectory != nil {
                        Button("Remove Folder", systemImage: "xmark") {
                            project.workingDirectory = nil
                        }
                        .labelStyle(.iconOnly)
                        .controlSize(.small)
                        .accessibilityLabel("Remove Folder")
                    }
                }
                .padding(Layout.padding)
                .background(Color.primary.opacity(0.05))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reference Files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontWeight(.medium)
                    Spacer()
                    
                    Text("\(project.resources.count) items")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                ZStack {
                    RoundedRectangle()
                        .fill(.background.opacity(0.5))
                        .overlay(
                            RoundedRectangle()
                                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                        )
                    
                    if project.resources.isEmpty {
                        EmptyFilesView()
                    } else {
                        FilesList()
                    }
                }
                .frame(minHeight: 150)
            }
            
            OpearationButtons()
        }
        .padding()
        .background(.ultraThinMaterial)
        .toolbar(content: ToolbarItems)
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

// MARK: - Subviews
extension ProjectEdition {
    
    @ViewBuilder
    func FilesList() -> some View {
        List(project.resources, id: \.self, selection: $selectedFiles) { url in
            ListCell(url)
                .listRowBackground(Color.clear)
                .listRowSeparator(.visible, edges: .bottom)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
    
    @ViewBuilder
    func EmptyFilesView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.quaternary)
            Text("No reference files added yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Browse Files") { resourceImporterPresented = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    func OpearationButtons() -> some View {
        HStack {
            Button {
                resourceImporterPresented = true
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            
            Button(role: .destructive, action: {
                project.removeResources(selectedFiles)
                selectedFiles.removeAll()
            }) {
                Label("Remove", systemImage: "trash")
            }
            .disabled(selectedFiles.isEmpty)
            
            Spacer()
        }
        .buttonStyle(.plain)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
        }
    }
    
    @ViewBuilder
    func ListCell(_ url: URL) -> some View {
        HStack {
            FileThumbnail(url: url)
                .frame(width: 20, height: 20)
            Text(url.lastPathComponent)
                .font(.subheadline)
        }
        .padding(.vertical, 4)
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

#Preview {
    ProjectEdition(project: .preview)
}
