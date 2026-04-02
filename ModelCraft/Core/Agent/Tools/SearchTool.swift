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
import Tokenizers

class SearchTool {
    
    static var allTools: [ToolSpec] {
        var tools = [
            searchMap.schema
        ]
        return tools
    }
    
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
        description: "Search for points of interest, restaurants, or locations nearby or in a specific area.",
        parameters: [
            .required("query", type: .string, description: "The search keyword."),
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
    
    static func searchRelevantDocuments(knowledgeBaseID: PersistentIdentifier) -> Tool<SearchRelevantDocumentsInput, SearchRelevantDocumentsOutput>{
        return Tool(
            name: "search_relevant_documents",
            description: "Search for information in the user's uploaded documents.",
            parameters: [
                .required("query", type: .string, description: "The keyword or question to search for in the document database."),
                .optional("numOfResults", type: .int, description: "The maximum number of results to return. Defaults to 10 if not specified.")
            ]
        ) { input in
            let knowledgaBaseModelActor = KnowledgaBaseModelActor(modelContainer: SwiftData.ModelContainer.shared)
            let docs = await knowledgaBaseModelActor.searchRelevantDocuments(knowledgeBaseID: knowledgeBaseID, query: input.query)
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
