//
//  MessageFileView.swift
//  ModelCraft
//
//  Created by Hongshen on 15/4/24.
//

import SwiftUI
import AVKit

struct MessageFileView: View {
    
    let url: URL
    
    @State private var isHovering: Bool = false
    let onDelete: () -> Void
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            MessageFileContentView(url: url)
                .padding([.top, .leading])
                
            
            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(
            RoundedRectangle().stroke(.separator, lineWidth: 1)
        )
        .cornerRadius()
        .onHover { isHovering = $0 }
    }
}


struct MessageFileContentView: View {
    
    let url: URL
    
    var body: some View {
        Group {
            if let type = UTType(filenameExtension: url.pathExtension),
               type.conforms(to: .movie) {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                FileThumbnail(url: url)
            }
        }.cornerRadius()
    }
}

#if DEBUG
#Preview {
    ScrollView {
        ForEach(PreviewResources.allCases) {
            MessageFileView(url: $0.url) {
                
            }
        }
    }
}
#endif
