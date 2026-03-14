//
//  ToolCallView.swift
//  ModelCraft
//
//  Created by Hongshen on 9/3/26.
//

import SwiftUI
import MapKit

import MLXLMCommon

struct ToolCallView: View {
    
    @State var toolCall: ToolCall
    @State var toolCallResult: String
    
    var body: some View {
        let arguments = toolCall.function.arguments
        switch toolCall.function.name {
        case ToolNames.executeCommand:
            Text(arguments["command"]?.stringValue ?? "No command")
        case ToolNames.searchMap:
            { () -> AnyView in
                
                do {
                    let places = try toolCallResult.decode(of: [MapPlace].self) ?? []
                    return AnyView(
                        Map {
                            ForEach(places) { place in
                                Marker(place.name,
                                       coordinate: .init(latitude: place.latitude, longitude: place.longitude))
                            }
                        }
                    )
                } catch {
                    return AnyView(Text("Failed to parse map data"))
                }
            }()
        case ToolNames.readFromFile, ToolNames.writeToFile:
            if let path = arguments["path"]?.stringValue {
                FilePreviewView(url: FileTool.resolvePath(path) )
            }
        case ToolNames.captureScreen:
            if let imageData = Data(base64Encoded: toolCallResult),
               let platformImage = PlatformImage(data: imageData){
                    Image(platformImage: platformImage)
                        .resizable()
                        .scaledToFit()
            }
        default:
            EmptyView()
        }
    }
}
