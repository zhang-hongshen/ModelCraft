//
//  DeleteButton.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 4/4/2024.
//

import SwiftUI

enum ButtonStyle {
    case iconOnly
    case textOnly
    case iconAndText
}

struct DeleteButton: View {
    
    var style: ButtonStyle = .iconAndText
    var action: () -> Void = {}
    
    var body: some View {
        Button(role: .destructive) {
            action()
        } label: {
            switch style {
            case .iconOnly:
                Image(systemName: "trash")
            case .textOnly:
                Text("Delete")
            case .iconAndText:
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview {
    DeleteButton()
    DeleteButton(style: .iconOnly)
    DeleteButton(style: .textOnly)
}
