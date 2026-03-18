//
//  AttachmentView.swift
//  ModelCraft
//
//  Created by Hongshen on 15/4/2024.
//

import SwiftUI
import AVKit

struct AttachmentView: View {
    
    @State var url: URL
    
    @State private var isHovering: Bool = false
    let onDelete: () -> Void
    
    var body: some View {
        AttachmentContentView(url: url)
            .overlay(alignment: .topLeading){
                if isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
            }
            .onHover { isHovering = $0 }
    }
}


struct AttachmentContentView: View {
    
    let url: URL
    
    var body: some View {
        Group {
            if let type = UTType(filenameExtension: url.pathExtension),
               type.conforms(to: .movie) {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                FileThumbnail(url: url)
            }
        }
    }
}
