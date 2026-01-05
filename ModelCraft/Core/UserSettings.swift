//
//  UserSettings.swift
//  ModelCraft
//
//  Created by Hongshen on 2/26/25.
//

import Foundation
import SwiftUI

@Observable
class UserSettings {
    var appearance: Appearance = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: UserDefaults.appearance) }
    }

    var automaticallyScrollToBottom = false {
        didSet { UserDefaults.standard.set(automaticallyScrollToBottom, forKey: UserDefaults.automaticallyScrollToBottom) }
    }

    var language = Locale.defaultLanguage {
        didSet { UserDefaults.standard.set(language, forKey: UserDefaults.language) }
    }

    var speakingRate = 0.5 {
        didSet { UserDefaults.standard.set(speakingRate, forKey: UserDefaults.speakingRate) }
    }

    var speakingVolume = 0.8 {
        didSet { UserDefaults.standard.set(speakingVolume, forKey: UserDefaults.speakingVolume) }
    }
}
