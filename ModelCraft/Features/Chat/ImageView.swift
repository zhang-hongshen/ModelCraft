//
//  ImageView.swift
//  ModelCraft
//
//  Created by Hongshen on 15/4/2024.
//

import SwiftUI

struct ImageView: View {
    
    let action: () -> Void
    
    @State var data: Data?
    @State private var isHovering: Bool = false
    
    init(data: Data?, action: @escaping () -> Void) {
        self.data = data
        self.action = action
    }
    
    var body: some View {
        ImageLoader(data: data, contentMode: .fit)
            .overlay(alignment: .topLeading){
                if isHovering {
                    Button(action: action) {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
            }
            .onHover(perform: { isHovering = $0 })
            .contextMenu {
                DeleteButton(style: .textOnly, action: action)
            }
    }
}

#Preview {
    ImageView(data: nil) {
        
    }
}
