//
//  CopyButton.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 13/4/2024.
//

import SwiftUI

struct CopyButton: View {
    
    var style: ButtonStyle = .iconAndText
    var action: () -> Void = {}
    
    @State private var copied = false
    
    var body: some View {
        Button {
            action()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                copied = false
            }
        } label: {
            switch style {
            case .iconOnly:
                Image(systemName: copied ? "checkmark" : "square.on.square")
            case .textOnly:
                Text(copied ? "Copied" : "Copy")
            case .iconAndText:
                Label(copied ? "Copied" : "Copy",
                      systemImage: copied ? "checkmark" : "square.on.square")
            }
        }
    }
}

#Preview {
    CopyButton()
}
