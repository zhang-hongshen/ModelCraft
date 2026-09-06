//
//  ViewExtensions.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI

struct SettingsModifier: ViewModifier {

    @AppStorage(UserDefaults.appearance)
    private var appearance = UserDefaultSettings.appearance

    @AppStorage(UserDefaults.language)
    private var language = UserDefaultSettings.language

    func body(content: Content) -> some View {
        content.preferredColorScheme({
            switch appearance {
            case .system:   nil
            case .light:    .light
            case .dark:     .dark
            }
        }())
        .environment(\.locale, .init(identifier: language))
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat = Layout.cornerRadius) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius))
    }

    func applyUserSettings() -> some View {
        modifier(SettingsModifier())
    }
}
