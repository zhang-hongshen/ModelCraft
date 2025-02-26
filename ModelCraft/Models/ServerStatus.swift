//
//  ServerStatus.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 2/26/25.
//

import SwiftUI

enum ServerStatus: String {
    
    case disconnected, launching, connected
    
    var localizedDescription: LocalizedStringKey {
        switch self {
        case .disconnected: "Disconnected"
        case .launching: "Launching"
        case .connected: "Connected"
        }
    }
}
