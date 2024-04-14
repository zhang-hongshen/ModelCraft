//
//  RandomAccessCollection+.swift
//  Arthub
//
//  Created by 张鸿燊 on 1/3/2024.
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
