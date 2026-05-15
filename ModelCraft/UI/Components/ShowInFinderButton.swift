//
//  ShowInFinderButton.swift
//  ModelCraft
//
//  Created by Hongshen on 13/5/26.
//

import SwiftUI

#if os(macOS)
struct ShowInFinderButton: View {
    
    let url: URL
    
    var body: some View {
        Button {
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("File doesn't exist: \(url.path)")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Show in Finder", systemImage: "magnifyingglass")
        }
    }
}
#endif
