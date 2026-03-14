//
//  Skill.swift
//  ModelCraft
//
//  Created by Hongshen on 8/3/26.
//

import Foundation

struct Skill: Identifiable, Codable {
    let id: UUID
    
    let name: String
    let description: String
    let location: URL
    let body: String?
    
    init(name: String, description: String, location: URL, body: String?) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.location = location
        self.body = body
    }
}
