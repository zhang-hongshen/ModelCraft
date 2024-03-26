//
//  TabView+.swift
//  Arthub
//
//  Created by 张鸿燊 on 27/2/2024.
//

import SwiftUI

struct AutoSizeModifier: ViewModifier {
    
    @State private var minSize: CGSize = .zero
    
    func body(content: Content) -> some View {
        content.background { GeometryReader { proxy in
            Color.clear.preference(
                key: TabViewMinSizePreference.self,
                value: proxy.size)}
        }
        .tabViewStyle(.automatic)
        .frame(minWidth: minSize.width, minHeight: minSize.height)
        .onPreferenceChange(TabViewMinSizePreference.self) { newValue in
            self.minSize = newValue
        }
    }
}

private struct TabViewMinSizePreference: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value.height = max(value.height, nextValue().height)
        value.width = max(value.width, nextValue().width)
    }
}

extension TabView {
    
    func autoSize() -> some View {
        self.modifier(AutoSizeModifier())
    }
}
