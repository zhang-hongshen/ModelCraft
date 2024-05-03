//
//  ImageView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 15/4/2024.
//

import SwiftUI

struct ImageView: View {
    
    @State var data: Data?
    let action: () -> Void
    
    @State private var isHovering: Bool = false
    
    init(data: Data?, action: @escaping () -> Void) {
        self.data = data
        self.action = action
    }
    
    var body: some View {
        ImageLoader(data: data, contentMode: .fit)
            .overlay(alignment: .bottomTrailing){
                if isHovering {
                    Button(action: action) {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
            }
            .onHover(perform: { isHovering = $0 })
            .contextMenu {
                DeleteButton(action: action)
            }
    }
}

#Preview {
    ImageView(data: nil) {
        
    }
}