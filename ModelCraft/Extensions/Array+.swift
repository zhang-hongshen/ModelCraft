//
//  Array+.swift
//  ModelCraft
//
//  Created by Hongshen on 20/2/26.
//

import Foundation

extension Array where Element: Encodable {
    
    func toString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(self)
        return String(data: jsonData, encoding: .utf8) ?? ""
    }
    
}
