//
//  String+.swift
//  ModelCraft
//
//  Created by Hongshen on 22/2/26.
//

import Foundation


extension String {
    
    func toArray<T: Decodable>(of type: T.Type) throws -> [T] {
        guard let data = self.data(using: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return try decoder.decode([T].self, from: data)
    }
}
