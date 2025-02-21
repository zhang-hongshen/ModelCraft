//
//  CopyButton.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 13/4/2024.
//

import SwiftUI

struct CopyButton: View {
    
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
            Image(systemName: copied ? "checkmark" : "square.on.square")
        }
    }
}

#Preview {
    CopyButton()
}
