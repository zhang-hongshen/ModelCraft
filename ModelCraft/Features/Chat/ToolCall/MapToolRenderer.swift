//
//  MapToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import MapKit

import MLXLMCommon


struct MapToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    var body: some View {

        switch status {

        case .running:

            ToolStatusView(toolCall: toolCall, status: status)

        case .completed:

            if let result,
               case let .text(text)? = result.content.first {

                if let output = try? text.text.decode(
                    of: SearchMapOutput.self
                ) {

                    Map {

                        ForEach(output.places) { place in

                            Marker(
                                place.name,
                                coordinate: CLLocationCoordinate2D(
                                    latitude: place.latitude,
                                    longitude: place.longitude
                                )
                            )
                        }
                    }
                    .frame(height: 240)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 18)
                    )

                } else {

                    ContentUnavailableView(
                        "Failed to load map",
                        systemImage: "map.slash",
                        description: Text("Failed to parse map data")
                    )
                }
            }

        default:
            ToolStatusView(toolCall: toolCall, status: status)
        }
    }
}

#Preview {
    ScrollView {
        let toolCall = ToolCall(function: .init(name: ToolNames.searchMap, arguments: ["query": "Beijing"]))
        
        VStack {
            MapToolRenderer(toolCall: toolCall, result: nil, status: .running)
            
            let searchOutput = SearchMapOutput(places: [
                MapPlace(name: "", address: "", latitude: 39.916, longitude: 116.397),
                MapPlace(name: "", address: "", latitude: 39.882, longitude: 116.407)
            ])
            if let jsonData = try? JSONEncoder().encode(searchOutput),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let result = CallToolResult(content: [.text(TextContent(text: jsonString))])
                MapToolRenderer(toolCall: toolCall, result: result, status: .completed)
                    .frame(height: 200)
            }
            
            MapToolRenderer(toolCall: toolCall, result: nil, status: .failed)
        }
        .padding()
        
    }
}
