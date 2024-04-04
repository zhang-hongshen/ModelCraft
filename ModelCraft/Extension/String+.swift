//
//  String+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 3/4/2024.
//

import Foundation

extension String {
    
    func split(separator: CharacterSet, chunkSize: Int) -> [String] {
        return components(separatedBy: separator).reduce(into: [String]()) { result, component in
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
