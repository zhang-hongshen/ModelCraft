//
//  UserMessageTemplate.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 2/26/25.
//

import Foundation

class UserMessage {
    
    static func question(_ question: String) -> Message {
        return Message(role: .user,
                       content: question)
    }
}
