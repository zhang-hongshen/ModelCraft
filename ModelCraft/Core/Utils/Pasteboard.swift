//
//  Pasteboard.swift
//  ModelCraft
//
//  Created by Hongshen on 30/3/2024.
//

import SwiftUI
import AppKit

enum Pasteboard {

    static func setString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
    
    static func setImage(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
