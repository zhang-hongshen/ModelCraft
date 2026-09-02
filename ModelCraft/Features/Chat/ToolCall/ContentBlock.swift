//
//  ContentBlock.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import AVKit

struct ContentBlocksView: View {

    let result: CallToolResult

    var body: some View {

        VStack(alignment: .leading, spacing: 12) {

            ForEach(
                Array(result.content.enumerated()),
                id: \.offset
            ) { _, block in

                ContentBlockView(block: block)
            }
        }
    }
}

struct ContentBlockView: View {

    let block: ContentBlock

    var body: some View {

        switch block {

        case .text(let text):

            Text(text.text)

        case .image(let imageContent):

            if let data = Data(base64Encoded: imageContent.data),
               let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(image.aspectRatio, contentMode: .fit)
                    .frame(maxHeight: 300)
                    .cornerRadius()
                    .contextMenu {
                        CopyButton() { Pasteboard.general.setImage(image) }
                    }
            }

        case .resourceLink(let link):

            ResourceLinkBlock(link: link)

        case .embeddedResource(let resource):

            EmbeddedResourceBlock(resource: resource)

        case .audio(let audioContent):

            if let data = Data(base64Encoded: audioContent.data) {

                AudioPlayer(
                    data: data,
                    mimeType: audioContent.mimeType
                )
            }
        }
    }
}

struct ResourceLinkBlock: View {

    let link: ResourceLink

    var body: some View {

        if let mimeType = link.mimeType {

            if mimeType.hasPrefix("image") {

                if let image = PlatformImage(contentsOfFile: link.url.path()) {

                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(image.aspectRatio, contentMode: .fit)
                        .frame(maxHeight: 300)
                        .cornerRadius()
                        .contextMenu {
                            CopyButton() { Pasteboard.general.setImage(image) }
#if os(macOS)
                            ShowInFinderButton(url: link.url)
#endif
                        }
                }

            } else if mimeType.hasPrefix("video") {

                VideoPlayer(
                    player: AVPlayer(url: link.url)
                )
                .frame(height: 300)
                .cornerRadius()

            } else if mimeType.hasPrefix("audio") {

                AudioPlayer(url: link.url)
            }

        } else {

            Link(link.title, destination: link.url)
        }
    }
}

struct EmbeddedResourceBlock: View {

    let resource: EmbeddedResource

    var body: some View {

        switch resource.resource {
            
        case .text(let textResource):
                
            Text(textResource.text)

        case .blob(let blobResource):
            Text(
                "Binary data (\(blobResource.mimeType ?? "unknown"))"
            )
        }
    }
}
