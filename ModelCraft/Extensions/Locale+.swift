//
//  Locale+.swift
//  ModelCraft
//
//  Created by Hongshen on 29/3/2024.
//

import Foundation

extension Locale {
    static var defaultLanguage: String {
        guard let language = Locale.preferredLanguages.first else {
            return Bundle.main.localizations.first!
        }
        if Bundle.main.localizations.contains(language) {
            return language
        }
        return Bundle.main.localizations.first!
    }
}
