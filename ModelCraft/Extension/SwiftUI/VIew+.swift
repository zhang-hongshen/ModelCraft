//
//  VIew+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI

struct SettingsModifier: ViewModifier {
    
    @AppStorage(UserDefaults.appearance)
    private var apperance = Appearance.system
    
    func body(content: Content) -> some View {
        content.preferredColorScheme({
                switch apperance {
                case .system:   nil
                case .light:    .light
                case .dark:     .dark
                }
            }())
    }
}

@available(iOS 13.4, macOS 10.15, *)
struct HoverEffectModifier: ViewModifier {
    
    @State private var isHovering = false
    
    func body(content: Content) -> some View {
        content.onHover { isHovering = $0 }
            .padding(5)
            .background {
                if isHovering {
                    RoundedRectangle().fill(.selection)
                }
            }
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat = Default.cornerRadius) -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: radius))
    }
    
    func applyUserSettings() -> some View {
        self.modifier(SettingsModifier())
    }
    
    @available(iOS 13.4, macOS 10.15, *)
    func hoverEffect() -> some View {
        self.modifier(HoverEffectModifier())
    }

}
