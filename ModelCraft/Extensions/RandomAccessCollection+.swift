//
//  RandomAccessCollection+.swift
//  ModelCraft
//
//  Created by Hongshen on 1/3/2024.
//

import Foundation

extension RandomAccessCollection where Element: Identifiable {
    
    func id(after id: Element.ID?) -> Element.ID? {
        guard let index = self.firstIndex(where: { $0.id == id }) else { return nil }
        let nextIndex = self.index(after: index)
        if nextIndex < self.endIndex {
            return self[nextIndex].id
        }
        return nil
    }
    
    func id(before id: Element.ID?) -> Element.ID? {
        guard let index = self.firstIndex(where: { $0.id == id }) else { return nil }
        let previousIndex = self.index(before: index)
        if previousIndex >= self.startIndex {
            return self[previousIndex].id
        }
        return nil
    }
    
    func element(before element: Element) -> Element? {
        guard let index = self.firstIndex(where: { $0.id == element.id }) else { return nil }
        let previousIndex = self.index(before: index)
        guard self.indices.contains(previousIndex) else { return nil }
        return self[previousIndex]
    }
    
    func element(after element: Element) -> Element? {
        guard let index = self.firstIndex(where: { $0.id == element.id }) else { return nil }
        let nextIndex = self.index(after: index)
        guard self.indices.contains(nextIndex) else { return nil }
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
