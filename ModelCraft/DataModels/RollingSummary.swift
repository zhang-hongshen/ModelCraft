//
//  RollingSummary.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 18/8/25.
//

import Foundation
import SwiftData

@Model
class RollingSummary {
    @Attribute(.unique) var id = UUID()
    var createdAt: Date = Date.now
    
    var chat: Chat
    var content: String
    
    init(id: UUID = UUID(), chat: Chat, content: String) {
        self.id = id
        self.chat = chat
        self.content = content
    }
}
