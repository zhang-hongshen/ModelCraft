//
//  Shortcuts.swift
//  ModelCraft
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let voiceInput = Self(
        "voiceInput",
        initial: initialShortcut(
            from: UserDefaults.voiceInputHotKey,
            default: .init(.space, modifiers: [.control, .option])))

    static let quickEntry = Self(
        "quickEntry",
        initial: initialShortcut(
            from: UserDefaults.quickEntryHotKey,
            default: .init(.space, modifiers: .option)))

    /// The package stores this initial value only when its own setting is absent,
    /// so later edits and cleared shortcuts take precedence over legacy settings.
    private static func initialShortcut(
        from legacyKey: String,
        default defaultShortcut: KeyboardShortcuts.Shortcut
    ) -> KeyboardShortcuts.Shortcut {
        guard let rawValue = UserDefaults.standard.string(forKey: legacyKey) else {
            return defaultShortcut
        }
        let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let keyCode = UInt16(parts[0]),
              let rawModifiers = UInt(parts[1])
        else { return defaultShortcut }
        let modifiers = NSEvent.ModifierFlags(rawValue: rawModifiers)
            .intersection([.control, .option, .shift, .command])
        // Modifier-only shortcuts cannot be registered by KeyboardShortcuts.
        guard !modifiers.isEmpty else { return defaultShortcut }
        return .init(.init(rawValue: Int(keyCode)), modifiers: modifiers)
    }
}
