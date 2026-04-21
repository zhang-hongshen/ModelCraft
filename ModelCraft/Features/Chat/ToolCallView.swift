//
//  ToolCallView.swift
//  ModelCraft
//
//  Created by Hongshen on 9/3/26.
//

import SwiftUI
import MapKit

import MLXLMCommon
import AVKit

struct ToolCallView: View {
    
    @State var toolCall: ToolCall
    @State var toolCallResult: CallToolResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(toolCallResult.content.enumerated()), id: \.offset) { _, block in
                contentView(for: block)
            }
        }
    }
    
}

extension ToolCallView {
    
    @ViewBuilder
    func contentView(for block: ContentBlock) -> some View {
        switch block {
            
        case .text(let text):
            let arguments = toolCall.function.arguments
            switch toolCall.function.name {
            case ToolNames.executeCommand:
                Text(arguments["command"]?.stringValue ?? "No command")
            case ToolNames.searchMap:
                mapView(for: text.text)
            case ToolNames.readFromFile, ToolNames.writeToFile:
                if let path = arguments["path"]?.stringValue {
                    FilePreviewView(url: PathResolver.resolve(path) )
                }
            default:
                EmptyView()
            }
        case .image(let image):
            if let data = Data(base64Encoded: image.data) {
               Image(data: data)!
                    .resizable()
                    .scaledToFit()
            }
            
        case .resourceLink(let link):
            resourceView(link)
            
        case .embeddedResource(let resource):
            embeddedResourceView(resource)
            
        case .audio(let audio):
            if let data = Data(base64Encoded: audio.data) {
                WaveformView(data: data, mimeType: audio.mimeType)
            }
        }
    }
        
    @ViewBuilder
    func resourceView(_ link: ResourceLink) -> some View {
        let url = URL(filePath: link.uri)
        
        if let mimeType = link.mimeType {
            if mimeType.hasPrefix("image") {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
            } else if mimeType.hasPrefix("video") {
                VideoPlayer(player: AVPlayer(url: url))
            }
        } else {
            Link(link.title, destination: url)
        }
    }
    
    @ViewBuilder
    func embeddedResourceView(_ resource: EmbeddedResource) -> some View {
        switch resource.resource {
            
        case .text(let text):
            Text(text.text)
            
        case .blob(let blob):
            Text("Binary data (\(blob.mimeType ?? "unknown"))")
        }
    }
}

extension ToolCallView {
    
    @ViewBuilder
    private func mapView(for toolCallResult: String) -> some View {
        if let output = try? toolCallResult.decode(of: SearchMapOutput.self) {
            Map {
                ForEach(output.places) { place in
                    Marker(place.name, coordinate: CLLocationCoordinate2D(
                        latitude: place.latitude,
                        longitude: place.longitude
                    ))
                }
            }
        } else {
            ContentUnavailableView(
                "Failed to load map",
                systemImage: "map.slash",
                description: Text("Failed to parse map data")
            )
        }
    }
}
