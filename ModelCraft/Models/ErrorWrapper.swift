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
    let guidance: LocalizedStringKey

    init(error: Error, guidance: LocalizedStringKey) {
        self.error = error
        self.guidance = guidance
    }
}
