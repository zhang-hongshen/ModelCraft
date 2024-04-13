/*
 See LICENSE folder for this sample’s licensing information.
 */

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
