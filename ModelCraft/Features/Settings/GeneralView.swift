//
//  GeneralView.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/24.
//

import SwiftUI

struct GeneralView: View {
    @Environment(UserSettings.self) private var userSettings

    var body: some View {
        @Bindable var userSettings = userSettings

        Form {
            Section {
                LabeledContent("Appearance") {
                    HStack(spacing: 8) {
                        AppearanceOptionButton(appearance: .system, selection: $userSettings.appearance)
                        AppearanceOptionButton(appearance: .light, selection: $userSettings.appearance)
                        AppearanceOptionButton(appearance: .dark, selection: $userSettings.appearance)
                    }
                }
            }

            Section {
                Picker("Language", selection: $userSettings.language) {
                    ForEach(Bundle.main.localizations, id: \.self) { languageCode in
                        if let language = Locale(identifier: languageCode)
                            .localizedString(forLanguageCode: languageCode) {
                            Text(verbatim: language).tag(languageCode)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceOptionButton: View {
    let appearance: Appearance
    @Binding var selection: Appearance

    private var title: LocalizedStringKey {
        switch appearance {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var body: some View {
        let isSelected = selection == appearance

        Button {
            selection = appearance
        } label: {
            VStack(spacing: 6) {
                AppearancePreview(appearance: appearance)
                    .aspectRatio(1.5, contentMode: .fit)

                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(6)
            .frame(width: 112)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accent.opacity(0.1) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accent : Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AppearancePreview: View {
    let appearance: Appearance

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if appearance != .dark {
                    AppearancePreviewPane(isDark: false)
                        .frame(width: paneWidth(in: geometry.size.width))
                }
                if appearance != .light {
                    AppearancePreviewPane(isDark: true)
                        .frame(width: paneWidth(in: geometry.size.width))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func paneWidth(in width: CGFloat) -> CGFloat {
        appearance == .system ? width / 2 : width
    }
}

private struct AppearancePreviewPane: View {
    let isDark: Bool

    private var backgroundColor: Color {
        isDark ? Color(red: 0.16, green: 0.17, blue: 0.19) : Color(red: 0.96, green: 0.96, blue: 0.97)
    }

    private var sidebarColor: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.045)
    }

    private var lineColor: Color {
        isDark ? Color.white.opacity(0.45) : Color.black.opacity(0.3)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color.red.opacity(0.75))
                Circle().fill(Color.gray.opacity(0.55))
                Circle().fill(Color.gray.opacity(0.55))
            }
            .frame(height: 5)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)

            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    ForEach(0..<3) { _ in
                        Capsule().fill(lineColor).frame(height: 2)
                    }
                }
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(sidebarColor)

                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(lineColor).frame(width: 20, height: 3)
                    Capsule().fill(lineColor.opacity(0.6)).frame(height: 2)
                    Capsule().fill(lineColor.opacity(0.6)).frame(width: 28, height: 2)
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(backgroundColor)
    }
}

#Preview {
    GeneralView().environment(UserSettings())
}
