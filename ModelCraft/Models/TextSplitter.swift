//
//  TextSplitter.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 11/4/2024.
//

import Foundation

class TextSplitter {
    
    private let separator: CharacterSet
    private let chunkSize: Int
    
    init(separator: CharacterSet = .newlines, chunkSize: Int = 100) {
        self.separator = separator
        self.chunkSize = chunkSize
    }
    
    func createDocuments(_ text: String) -> [String] {
        return text.components(separatedBy: separator).reduce(into: [String]()) { result, component in
            var component = component
            while component.count > chunkSize {
                let index = component.index(component.startIndex, offsetBy: chunkSize)
                result.append(String(component[..<index]))
                component = String(component[index...])
            }
            result.append(component)
        }
    }
}
