//
//  InfoButton.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 14/4/2024.
//

import SwiftUI

struct InfoButton: View {
    
    var action: () -> Void = {}
    
    var body: some View {
        Button("Info",
               systemImage: "info.circle") {
            action()
        }
    }
}

#Preview {
    InfoButton()
}
