//
//  ViewMode.swift
//  ModelCraft
//
//  Created by Hongshen on 13/3/26.
//

enum ViewMode: String, CaseIterable, Identifiable {
    
    case list = "as List"
    case grid = "as Grid"
    
    var id: String { self.rawValue }
    
    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}
