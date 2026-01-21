//
//  ErrorWrapper.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/2025.
//

import Foundation
import SwiftUI

struct ErrorWrapper: Identifiable {
    let id = UUID()
    let localizedDescription: String
    let recoverySuggestion: String

    init(localizedDescription: String = "", recoverySuggestion: String = "") {
        self.localizedDescription = localizedDescription
        self.recoverySuggestion = recoverySuggestion
    }
    
    init(error: Error, recoverySuggestion: String = "") {
        self.localizedDescription = error.localizedDescription
        self.recoverySuggestion = recoverySuggestion
    }
    
    init(error: LocalizedError) {
        self.localizedDescription = error.localizedDescription
        self.recoverySuggestion = error.recoverySuggestion ?? ""
    }
}
