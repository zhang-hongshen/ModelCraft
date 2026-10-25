//
//  Pasteboard.swift
//  ModelCraft
//
//  Created by Hongshen on 30/3/24.
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

    /// Copies the file itself, as Finder does, so pasting inserts or duplicates the file.
    static func setFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
}
