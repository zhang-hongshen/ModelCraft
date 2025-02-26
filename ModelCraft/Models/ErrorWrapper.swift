//
//  ErrorWrapper.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/2/2025.
//

import Foundation
import SwiftUI

struct ErrorWrapper: Identifiable {
    let id = UUID()
    let error: Error
    let recoverySuggestion: String

    init(error: Error, recoverySuggestion: String) {
        self.error = error
        self.recoverySuggestion = recoverySuggestion
    }
    
    init(error: LocalizedError) {
        self.error = error
        self.recoverySuggestion = error.recoverySuggestion ?? ""
    }
}
