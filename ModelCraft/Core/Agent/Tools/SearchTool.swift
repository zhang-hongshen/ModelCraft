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

class SearchTool {
    
    static let allTools: [any ToolProtocol] = [
        searchMap
    ]
    
    static func searchMap(query: String, useCurrentLocation: Bool = false, numOfResults: Int) async throws -> [MapPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if useCurrentLocation, let userLoc = LocationManager.shared.currentLocation?.coordinate {
            print("latitude:,\(userLoc.latitude) longitude:\(userLoc.longitude)")
            let span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            request.region = MKCoordinateRegion(center: userLoc, span: span)
        }
        
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        let items = response.mapItems.prefix(numOfResults)
        
        if items.isEmpty {
            return []
        }
        
        return items.map { item in
            var distanceInMeters: Double? = nil
            if let userClloc = LocationManager.shared.currentLocation,
               let itemClloc = item.placemark.location {
                distanceInMeters = userClloc.distance(from: itemClloc)
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
    
    static func searchRelevantDocuments(projectID: PersistentIdentifier) -> Tool<SearchRelevantDocumentsInput, SearchRelevantDocumentsOutput>{
        return Tool(
            name: "search_relevant_documents",
            description: "Search the current project's indexed documents for passages relevant to a question. Use this to ground an answer in files the user added to the project; it returns matching text passages, not web results or arbitrary local files.",
            parameters: [
                .required("query", type: .string, description: "The specific question, concept, or keywords to match against the current project's indexed document content."),
                .optional("numOfResults", type: .int, description: "The maximum number of results to return. Defaults to 10 if not specified.")
            ]
        ) { input in
            let actor = ProjectModelActor(modelContainer: SwiftData.ModelContainer.shared)
            let docs = await actor.searchRelevantDocuments(
                projectID: projectID,
                query: input.query,
                numOfResults: input.numOfResults)
            return SearchRelevantDocumentsOutput(docs: docs)
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

struct SearchRelevantDocumentsInput: Codable {
    let query: String
    let numOfResults: Int?
}

struct SearchRelevantDocumentsOutput: Codable {
    let docs: [String]
}
