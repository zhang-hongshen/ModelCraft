//
//  ModelEntity.swift
//  ModelCraft
//
//  Created by Hongshen on 2/4/26.
//

protocol ModelEntity: Identifiable {
    var id: String { get }
    var displayName: String { get }
}

extension ModelEntity {
    var displayName: String {
        id.components(separatedBy: "/").last ?? id
    }
}
