//
//  FileThumbnail.swift
//  ModelCraft
//
//  Created by Hongshen on 2/4/2024.
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

struct FileThumbnail: View {
    
    @State var url: URL
    @State private var previewImage: PlatformImage? = nil
    
    var frameWidth: CGFloat = 80
    
    var image: Image {
        if let previewImage {
            Image(platformImage: previewImage)
        } else {
            Image(systemName: url.hasDirectoryPath ? "folder" : "doc.text")
        }
    }
    
    var body: some View {
        image.resizable()
            .aspectRatio(contentMode: .fit)
            .task { generateThumbnailRepresentations() }
    }
}

extension FileThumbnail {
    func generateThumbnailRepresentations() {
        // Create the thumbnail request.
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: frameWidth, height: frameWidth),
                                                   scale: 1,
                                                   representationTypes: .all)
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnailOrNil, _, errorOrNil in
            guard let thumbnail = thumbnailOrNil else { return }
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
    FileThumbnail(url: URL(fileURLWithPath: "1231"))
}
