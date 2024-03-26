//
//  ImageButton.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import SwiftUI

// MARK: TagGesture Area is the image

struct ImageButton<Label>: View where Label: View {
    var systemImage: String
    var label: () -> Label
    var action: () -> Void
    
    init(action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label) {
        self.systemImage = ""
        self.label = label
        self.action = action
    }
    
    init(systemImage: String, 
         action: @escaping () -> Void = {},
         @ViewBuilder label: @escaping () -> Label = { EmptyView() }) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }
    
    var body: some View {
        GeometryReader { proxy in
            Rectangle().fill(.ultraThinMaterial.opacity(0.5))
                .overlay {
                    Button(action: action) {
                        Group {
                            if systemImage != "" {
                                Image(systemName: systemImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            }
                            else {
                                label()
                            }
                        }
                        .frame(width: proxy.size.width / 4,
                               height: proxy.size.height / 4)
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
        }
    }
}

#Preview {
    ImageButton(systemImage: "photo")
}
