//
//  RandomAccessCollection+.swift
//  ModelCraft
//
//  Created by Hongshen on 1/3/2024.
//

import Foundation

extension RandomAccessCollection where Element: Equatable {
    
    func element(before element: Element) -> Element? {
        guard let index = self.firstIndex(of: element),
              index > self.startIndex else { return nil }
        let previousIndex = self.index(before: index)
        return self[previousIndex]
    }
    
    
    func element(after element: Element) -> Element? {
        guard let index = self.firstIndex(of: element) else { return nil }
        let nextIndex = self.index(after: index)
        guard nextIndex < self.endIndex else { return nil }
        return self[nextIndex]
    }
}
    
extension RandomAccessCollection where Element == Message {
    
    func toString() -> String {
        return self.map { msg in
            let roleTag: String
            switch msg.role {
            case .user:      roleTag = "user"
            case .assistant: roleTag = "assistant"
            case .tool:      roleTag = "tool"
            default:         roleTag = "other"
            }
            return "<\(roleTag)>\(msg.content)</\(roleTag)>"
        }.joined(separator: "\n")
    }
}
