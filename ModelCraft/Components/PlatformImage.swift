//
//  PlatformImage.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import SwiftUI

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif

extension PlatformImage {
    var aspectRatio: CGFloat {
        size.width / size.height
    }
}
