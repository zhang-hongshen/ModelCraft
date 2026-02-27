//
//  JSONEncoder+.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/26.
//

import Foundation

internal extension JSONEncoder {
    static var `default`: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        
        return encoder
    }
}
