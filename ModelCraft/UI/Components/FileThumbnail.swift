//
//  FileThumbnail.swift
//  ModelCraft
//
//  Created by Hongshen on 2/4/2024.
//

import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

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
            Image(systemName: systemImageName(for: url))
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
    
    func systemImageName(for url: URL) -> String {
        
        if url.hasDirectoryPath {
            return "folder"
        }
        
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return "document"
        }
        
        if type.conforms(to: .image) {
            return "photo"
        }
        
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return "video"
        }
        
        if type.conforms(to: .audio) {
            return "waveform"
        }
        
        if type.conforms(to: .pdf) {
            return "richtext.page"
        }
        
        if type.conforms(to: .plainText) || type.conforms(to: .text) {
            return "text.document"
        }
        
        if type.conforms(to: .json) {
            return "curlybraces"
        }
        
        if type.conforms(to: .spreadsheet) {
            return "tablecells"
        }
        
        if type.conforms(to: .presentation) {
            return "display"
        }
        
        return "document"
    }
}
    
#Preview {
    FileThumbnail(url: URL(fileURLWithPath: "1231"))
}
