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
            ForEach(project.files, id: \.self) { url in
                ListCell(url).tag(url)
            }
            .onDelete {
                project.files.remove(atOffsets: $0)
            }
        }
        .listStyle(.inset)
        .contextMenu {
            DeleteButton(style: .textOnly) {
                project.removeFiles(selectedFiles)
            }
        }
        #if os(macOS)
        .onDeleteCommand {
            project.removeFiles(selectedFiles)
        }
        #endif
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
    ProjectFileView(project: Project())
}
