//
//  PlatformColor.swift
//  ModelCraft
//
//  Created by Hongshen on 9/3/26.
//

import SwiftUI

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#endif

extension Color {
    
    init(platformColor: PlatformColor) {
        #if canImport(AppKit)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }
}
