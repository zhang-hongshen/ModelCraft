//
//  Image+.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/24.
//

import SwiftUI
import AppKit

extension Image {
    
    init?(data: Data) {
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
    }
}
