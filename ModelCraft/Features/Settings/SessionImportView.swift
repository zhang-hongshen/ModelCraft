//
//  SessionImportView.swift
//  ModelCraft
//
//  Created by Hongshen on 31/10/26.
//

import SwiftUI

/// Imports the sessions of an agent app chosen from a menu: "Import from [app] Load".
struct SessionImportView: View {

    @State private var source = SessionSource.claudeCode
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        HStack {
            Picker("Import from", selection: $source) {
                ForEach(SessionSource.allCases) { source in
                    Label {
                        Text(verbatim: source.name)
                    } icon: {
                        source.icon
                    }
                    .tag(source)
                }
            }
            .fixedSize()

            Button("Load", action: importSessions)

            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(isImporting)
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func importSessions() {
        isImporting = true
        Task {
            do {
                try await source.importSessions()
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }
}

private extension SessionSource {

    /// The app's icon at menu size; menus draw images at their own size, ignoring frames.
    var icon: Image {
        let image = NSImage(named: imageName)!.copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return Image(nsImage: image)
    }
}

#Preview {
    SessionImportView()
        .padding()
}
