//
//  SearchTool.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import Foundation
import MapKit

class SearchTool {
    
    static func searchMap(query: String, useCurrentLocation: Bool = false, numOfResults: Int = 5) async throws -> [MapPlace] {
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
}
