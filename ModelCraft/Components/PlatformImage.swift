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
    
    func save(to url: URL) throws {
        #if canImport(UIKit)
        guard let pngData = self.pngData() else {
            print("Failed to convert UIImage to PNG data")
            return
        }
        #elseif canImport(AppKit)
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("Failed to convert NSImage to PNG data")
            return
        }
        #endif
        try pngData.write(to: url)
        print("Saved image to \(url.path)")
    }
}
