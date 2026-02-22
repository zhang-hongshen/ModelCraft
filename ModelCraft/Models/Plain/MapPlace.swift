//
//  MapPlace.swift
//  ModelCraft
//
//  Created by Hongshen on 21/2/26.
//

import Foundation

struct MapPlace: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let distanceInMeters: Double?
    let phoneNumber: String?
    let website: String?
    
    init(name: String, address: String, latitude: Double, longitude: Double, distanceInMeters: Double?,
         phoneNumber: String?, website: String?) {
        self.id = UUID()
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.distanceInMeters = distanceInMeters
        self.phoneNumber = phoneNumber
        self.website = website
    }
    
    var distance: String? {
        guard let meters = distanceInMeters else { return nil }
        
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 1
        
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return formatter.string(from: measurement)
    }
    
}
