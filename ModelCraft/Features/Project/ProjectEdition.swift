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
    @State private var fileImporterPresented: Bool = false
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
                HStack {
                    Text("Source Files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontWeight(.medium)
                    Spacer()
                    
                    Text("\(project.files.count) items")
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
                    
                    if project.files.isEmpty {
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
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.data, .folder, .pdf, .text],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                project.files.append(contentsOf: urls)
            }
        }
    }
}

// MARK: - Subviews
extension ProjectEdition {
    
    @ViewBuilder
    func FilesList() -> some View {
        List(project.files, id: \.self, selection: $selectedFiles) { url in
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
            Text("No files added yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Browse Files") { fileImporterPresented = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    func OpearationButtons() -> some View {
        HStack {
            Button {
                fileImporterPresented = true
            } label: {
                Label("Add Files", systemImage: "plus.circle")
            }
            
            Button(role: .destructive, action: {
                project.removeFiles(selectedFiles)
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
    
}

#Preview {
    ProjectEdition(project: Project())
}
