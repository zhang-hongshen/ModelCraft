//
//  Image+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI

extension Image {
    init?(data: Data) {
        guard let image = PlatformImage(data: data) else { return nil }
#if canImport(AppKit)
        self.init(nsImage: image)
#elseif canImport(UIKit)
        self.init(uiImage: image)
#endif
    }
}
