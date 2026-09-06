//
//  LocationManager.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import CoreLocation

final class LocationManager: NSObject, CLLocationManagerDelegate {
    
    static let shared = LocationManager()
    
    private let manager = CLLocationManager()
    var currentLocation: CLLocation?
    
    func checkLocationAuthorization() {
        
        manager.delegate = self
        manager.startUpdatingLocation()
        
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            
        case .restricted:
            print("Location restricted")
            
        case .denied:
            print("Location denied")
            
        case .authorizedAlways:
            print("Location authorizedAlways")
            
        case .authorizedWhenInUse:
            print("Location authorized when in use")
            currentLocation = manager.location
            
        @unknown default:
            print("Location service disabled")
        
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        checkLocationAuthorization()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.first
    }
}
