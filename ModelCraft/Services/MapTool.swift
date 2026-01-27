//
//  MapTool.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import Foundation
import MapKit

class MapTool {
    
    static func search(query: String, useCurrentLocation: Bool = false) async throws -> [PlaceDetail] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if useCurrentLocation, let userLoc = LocationManager.shared.currentLocation?.coordinate {
            print("latitude:,\(userLoc.latitude) longitude:\(userLoc.longitude)")
            let span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            request.region = MKCoordinateRegion(center: userLoc, span: span)
        }
        
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        let items = response.mapItems.prefix(6)
        
        if items.isEmpty {
            return []
        }
        
        
        return items.map { item -> PlaceDetail in
            var distanceText: String? = nil
            if let userClloc = LocationManager.shared.currentLocation,
               let itemClloc = item.placemark.location {
                let meters = userClloc.distance(from: itemClloc)
                distanceText = meters > 1000 ? String(format: "%.1fkm", meters/1000) : "\(Int(meters))m"
            }
            
            return PlaceDetail(
                name: item.name ?? "Unknown",
                address: item.placemark.title ?? "Unknown Address",
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude,
                distance: distanceText,
                phoneNumber: item.phoneNumber,
                website: item.url?.absoluteString
            )
        }
    }
}

struct PlaceDetail: Codable {
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let distance: String?
    let phoneNumber: String?
    let website: String?
}

