//
//  DeleteButton.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 4/4/2024.
//

import SwiftUI

struct DeleteButton: View {
    
    var action: () -> Void = {}
    
    var body: some View {
        Button(role: .destructive) {
            action()
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Delete")
            }
        }
    }
}

#Preview {
    DeleteButton()
}
