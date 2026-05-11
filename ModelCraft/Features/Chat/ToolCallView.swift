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
    @State var toolCallResult: CallToolResult?
    @State var toolCallStatus: ToolCallStatus
    @State private var isPresented: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isPresented) {
            if let toolCallResult = toolCallResult {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(toolCallResult.content.enumerated()), id: \.offset) { _, block in
                        contentView(for: block)
                    }
                }
            } else {
                ProgressView()
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                if toolCallStatus == .running {
                    ProgressView()
                }
                Text(toolCall.localizedDescription(toolCallStatus: toolCallStatus))
            }
        }
        
    }
    
}

extension ToolCallView {
    
    @ViewBuilder
    func contentView(for block: ContentBlock) -> some View {
        switch block {
            
        case .text(let textContent):
            let arguments = toolCall.function.arguments
            switch toolCall.function.name {
            case ToolNames.executeCommand:
                Text(arguments["command"]?.stringValue ?? "No command")
            case ToolNames.searchMap:
                mapView(for: textContent.text)
            case ToolNames.readFromFile, ToolNames.writeToFile:
                if let path = arguments["path"]?.stringValue {
                    FilePreviewView(url: PathResolver.resolve(path) )
                }
            default:
                EmptyView()
            }
        case .image(let imageContent):
            if let data = Data(base64Encoded: imageContent.data),
                let image = Image(data: data){
                image
                    .resizable()
                    .scaledToFit()
            }
            
        case .resourceLink(let link):
            resourceLinkView(link)
            
        case .embeddedResource(let resource):
            embeddedResourceView(resource)
            
        case .audio(let audio):
            if let data = Data(base64Encoded: audio.data) {
                WaveformView(data: data, mimeType: audio.mimeType)
            }
        }
    }
        
    @ViewBuilder
    func resourceLinkView(_ link: ResourceLink) -> some View {
        
        if let mimeType = link.mimeType {
            if mimeType.hasPrefix("image") {
                if let image = PlatformImage(contentsOf: link.url) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .contextMenu {
                            CopyButton() {
                                Pasteboard.general.setImage(image)
                            }
                        }
                }
            } else if mimeType.hasPrefix("video") {
                VideoPlayer(player: AVPlayer(url: link.url))
            }
        } else {
            Link(link.title, destination: link.url)
        }
    }
    
    @ViewBuilder
    func embeddedResourceView(_ resource: EmbeddedResource) -> some View {
        switch resource.resource {
            
        case .text(let textResourceContent):
            Text(textResourceContent.text)
            
        case .blob(let blobResourceContent):
            Text("Binary data (\(blobResourceContent.mimeType ?? "unknown"))")
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

#Preview {
    
    let toolCall = ToolCall(function: .init(name: ToolNames.textToImage,
                                            arguments: ["prompt": "a horse"]))
    let url = URL.picturesDirectory.appendingPathComponent("1F74F501-B5DF-48FE-B3EB-882269A21495", conformingTo: .png)
    let resourceLink = ResourceLink(url: url, mimeType: "image/png")
    print(FileManager.default.fileExists(atPath: url.path))
    let toolCallResult = CallToolResult(content: [.resourceLink(resourceLink)])
    
    return ToolCallView(toolCall: toolCall,
                 toolCallResult: toolCallResult,
                 toolCallStatus: .completed)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
