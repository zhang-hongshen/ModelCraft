//
//  ShortcutsView.swift
//  ModelCraft
//

import SwiftUI
import KeyboardShortcuts

struct ShortcutsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Voice input", name: .voiceInput)
                KeyboardShortcuts.Recorder("Quick Entry", name: .quickEntry)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    ShortcutsView()
}
