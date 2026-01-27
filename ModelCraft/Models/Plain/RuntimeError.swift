//
//  RuntimeError.swift
//  ModelCraft
//
//  Created by Hongshen on 2/25/25.
//

import Foundation

struct RuntimeError: LocalizedError {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? {
        description
    }
}
