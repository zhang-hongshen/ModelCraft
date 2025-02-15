//
//  Prompt.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 14/4/2024.
//

import Foundation
import SwiftData

@Model
class Prompt {
    @Attribute(.unique) let id = UUID()
    let createdAt: Date = Date.now
    var title: String
    var command: String
    var content: String
    
    init(title: String = "", command: String = "", content: String = "") {
        self.title = title
        self.command = command
        self.content = content
    }
}
