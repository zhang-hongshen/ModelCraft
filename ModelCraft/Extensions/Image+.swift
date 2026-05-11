//
//  Image+.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI

extension Image {
    
    init?(data: Data) {
        guard let pImage = PlatformImage(data: data) else { return nil }
        self.init(platformImage: pImage)
    }
    
    init(platformImage image: PlatformImage) {
#if canImport(AppKit)
        self.init(nsImage: image)
#elseif canImport(UIKit)
        self.init(uiImage: image)
#endif
    }
}
