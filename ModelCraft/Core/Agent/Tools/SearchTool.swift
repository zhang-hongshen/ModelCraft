//
//  SearchTool.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import Foundation
import SwiftData
import MapKit

import MLXLMCommon

enum SearchTool {
    
    static let allTools: [any ToolProtocol] = [
        searchMap
    ]
    
    static func searchMap(query: String, useCurrentLocation: Bool = false, numOfResults: Int) async throws -> [MapPlace] {
        try Task.checkCancellation()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if useCurrentLocation, let userLoc = LocationManager.shared.currentLocation?.coordinate {
            print("latitude:,\(userLoc.latitude) longitude:\(userLoc.longitude)")
            let span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            request.region = MKCoordinateRegion(center: userLoc, span: span)
        }
        
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler {
            try await search.start()
        } onCancel: {
            search.cancel()
        }
        try Task.checkCancellation()
        let items = response.mapItems.prefix(numOfResults)
        
        if items.isEmpty {
            return []
        }
        
        return items.map { item in
            var distanceInMeters: Double? = nil
            if let userLocation = LocationManager.shared.currentLocation,
               let itemLocation = item.placemark.location {
                distanceInMeters = userLocation.distance(from: itemLocation)
            }
            
            return MapPlace(
                name: item.name ?? "Unknown",
                address: item.placemark.title ?? "Unknown Address",
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude,
                distanceInMeters: distanceInMeters,
                phoneNumber: item.phoneNumber,
                website: item.url?.absoluteString
            )
        }
    }
    
    static let searchMap = Tool<SearchMapInput, SearchMapOutput>(
        name: "search_map",
        description: "Search Apple Maps for real-world places such as businesses, restaurants, landmarks, or addresses. Returns matching names, addresses, coordinates, and available contact details; distance is available when current-location search is enabled.",
        parameters: [
            .required("query", type: .string, description: "A place name, category, address, or natural-language location query. Include a city or area when the search is not near the user."),
            .required("useCurrentLocation", type: .bool, description: "Set to true if the user implies their current location. Set to false if a specific city or remote location is mentioned."),
            .optional("numOfResults",
                      type: .int,
                      description: "The maximum number of results to return. Defaults to 5 if not specified.")
        
        ]
    ) { input in
        
        let places = try await SearchTool.searchMap(
            query: input.query,
            useCurrentLocation: input.useCurrentLocation,
            numOfResults: input.numOfResults ?? 5)
        return SearchMapOutput(places: places)
    }
    
    static func searchProject(projectID: PersistentIdentifier) -> Tool<SearchProjectInput, SearchProjectOutput> {
        return Tool(
            name: ToolNames.searchProject,
            description: "Search the current project's working folder and read-only reference files. Source code is parsed with SwiftSyntax or Tree-sitter and ranked using definitions, references, and caller-callee relationships; configuration and data files use structured keys; documents and transcripts use hybrid keyword and semantic retrieval. A local reranker combines those signals according to whether the task is understanding, locating, or editing. Use direct read_file instead when the exact path is already known. Results include absolute paths and precise line, section, or document locations so a matching source file can be read before editing. This is local project search, not web search.",
            parameters: [
                .required("query", type: .string, description: "A focused concept, filename, code symbol, configuration key, error text, or natural-language question to find in the project."),
                .optional("purpose", type: .string, description: "How the results will be used: automatic, understand, locate, or edit. Defaults to automatic. Use understand for answering from project knowledge, locate for finding definitions or files, and edit before changing code."),
                .optional("numOfResults", type: .int, description: "The maximum number of ranked results to return. Defaults to 10 if not specified.")
            ]
        ) { input in
            try Task.checkCancellation()
            let actor = ProjectModelActor(modelContainer: SwiftData.ModelContainer.shared)
            let results = await actor.searchProject(
                projectID: projectID,
                query: input.query,
                purpose: ProjectSearchPurpose(rawValue: input.purpose ?? "") ?? .automatic,
                numOfResults: input.numOfResults)
            try Task.checkCancellation()
            return SearchProjectOutput(results: results)
        }
    }
}


struct SearchMapInput: Codable {
    let query: String
    let useCurrentLocation: Bool
    let numOfResults: Int?
}

struct SearchMapOutput: Codable {
    let places: [MapPlace]
}

struct SearchProjectInput: Codable {
    let query: String
    let purpose: String?
    let numOfResults: Int?
}

struct SearchProjectOutput: Codable {
    let results: [ProjectSearchResult]
}
