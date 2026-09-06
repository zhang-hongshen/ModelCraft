//
//  ProjectFileView.swift
//  ModelCraft
//
//  Created by Hongshen on 3/4/2024.
//

import SwiftUI

struct ProjectFileView: View {
    
    @Bindable var project: Project
    @State private var selectedFiles: Set<URL> = []
    
    var body: some View {
        List(selection: $selectedFiles) {
            if let workingDirectory = project.workingDirectory {
                Section("Working Folder") {
                    ListCell(workingDirectory)
                        .contextMenu {
                            Button("Remove Folder") {
                                project.workingDirectory = nil
                            }
                        }
                }
            }

            Section("Reference Files") {
                ForEach(project.resources, id: \.self) { url in
                    ListCell(url).tag(url)
                }
                .onDelete {
                    project.removeResources(atOffsets: $0)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu {
            DeleteButton(style: .textOnly) {
                project.removeResources(selectedFiles)
            }
        }
        .onDeleteCommand {
            project.removeResources(selectedFiles)
        }
    }
    
    @ViewBuilder
    func ListCell(_ url: URL) -> some View {
        Label {
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            FileThumbnail(url: url)
        }
    }
}

#Preview {
    ProjectFileView(project: .preview)
}
