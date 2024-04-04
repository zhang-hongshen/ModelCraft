//
//  FileItem.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 2/4/2024.
//

import SwiftUI
import QuickLookThumbnailing

enum ViewType: Identifiable, CaseIterable {
    case grid, list
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }
    var localizedDescription: LocalizedStringKey {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }
}

struct FileItem: View {
    
    @State var url: URL
    @State var layout: ViewType = .list
    var frameWidth: CGFloat = 80
    @State private var previewImage: PlatformImage? = nil
    
    var image: Image {
        if let previewImage {
            Image(platformImage: previewImage)
        } else {
            Image(systemName: url.hasDirectoryPath ? "folder" : "doc.text")
        }
    }
    
    
    var body: some View {
        ContentView()
            .task { generateThumbnailRepresentations() }
            .onChange(of: layout, initial: true, generateThumbnailRepresentations)
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        switch layout {
        case .list:
            ListView()
        case .grid:
            GridView()
        }
    }
    
    @ViewBuilder
    func ListView() -> some View {
        Label {
            Text(url.lastPathComponent).truncationMode(.middle)
        } icon: {
            image.resizable()
                .aspectRatio(1, contentMode: .fit)
        }
    }
    
    @ViewBuilder
    func GridView() -> some View {
        VStack {
            image.resizable()
                .aspectRatio(1, contentMode: .fit)
                .frame(width: frameWidth)
            
            Text(url.lastPathComponent)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .frame(width: frameWidth)
    }
    
}

extension FileItem {
    func generateThumbnailRepresentations() {
        var size: CGSize {
            switch layout {
            case .list:
                return CGSize(width: 25, height: 25)
            case .grid:
                return CGSize(width: frameWidth, height: frameWidth)
            }
        }
        // Create the thumbnail request.
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: size,
                                                   scale: 1,
                                                   representationTypes: .icon)
        // Retrieve the singleton instance of the thumbnail generator and generate the thumbnails.
        let generator = QLThumbnailGenerator.shared
        generator.generateBestRepresentation(for: request) { thumbnail, error in
            guard let thumbnail else { return }
            DispatchQueue.main.async {
#if canImport(AppKit)
                previewImage = thumbnail.nsImage
#elseif canImport(UIKit)
                previewImage = thumbnail.uiImage
#endif
            }
        }
    }
}
    
#Preview {
    FileItem(url: URL(fileURLWithPath: "1231"))
}
