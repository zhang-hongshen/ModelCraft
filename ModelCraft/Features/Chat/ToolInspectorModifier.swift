//
//  ToolInspectorModifier.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 12/3/26.
//

import SwiftUI

struct ToolInspectorModifier: ViewModifier {
    
    @Binding var isPresented: Bool
    let content: AnyView
    
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content baseContent: Content) -> some View {
        if sizeClass == .regular {
            baseContent
                .inspector(isPresented: $isPresented) {
                    content
                }
        } else {
            baseContent
                .sheet(isPresented: $isPresented) {
                    content
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
        }
    }
}

extension View {
    func toolInspector(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        self.modifier(ToolInspectorModifier(isPresented: isPresented, content: AnyView(content())))
    }
}
