//
//  String+.swift
//  ModelCraft
//
//  Created by Hongshen on 22/2/26.
//

import Foundation
import CryptoKit

extension String {
    
    func decode<T: Decodable>(of type: T.Type) throws -> T? {
        guard let data = self.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
    
    var sha256String: String {
        guard let data = self.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
