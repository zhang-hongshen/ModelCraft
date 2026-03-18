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
            mapView(for: toolCallResult)
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
