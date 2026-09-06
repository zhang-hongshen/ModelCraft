//
//  NSImage+.swift
//  ModelCraft
//
//  Created by Hongshen on 24/3/2024.
//

import AppKit

extension NSImage {

    var aspectRatio: CGFloat {
        size.width / size.height
    }
    
    func save(to url: URL) throws {
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("Failed to convert NSImage to PNG data")
            return
        }
        try pngData.write(to: url)
        print("Saved image to \(url.path)")
    }
}
