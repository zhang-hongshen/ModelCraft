//
//  Pasteboard.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 30/3/2024.
//

import SwiftUI

class Pasteboard {
    
    static let general = Pasteboard()
    
    func setString(_ string: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = string
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
#endif
    }
    
}
