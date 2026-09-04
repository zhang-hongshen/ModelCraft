//
//  UserSettings.swift
//  ModelCraft
//
//  Created by Hongshen on 2/26/25.
//

import Foundation
import SwiftUI

@MainActor
@Observable
class UserSettings {
    var modelDownloadBaseDirectory = UserDefaults.standard.url(
        forKey: UserDefaults.modelDownloadBaseDirectory
    ) ?? UserDefaultSettings.modelDownloadBaseDirectory {
        didSet {
            UserDefaults.standard.set(
                modelDownloadBaseDirectory,
                forKey: UserDefaults.modelDownloadBaseDirectory
            )
        }
    }
    
    var appearance = UserDefaultSettings.appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: UserDefaults.appearance) }
    }

    var language = UserDefaultSettings.language {
        didSet { UserDefaults.standard.set(language, forKey: UserDefaults.language) }
    }

    var speakingRate = UserDefaultSettings.speakingRate {
        didSet { UserDefaults.standard.set(speakingRate, forKey: UserDefaults.speakingRate) }
    }

    var speakingVolume = UserDefaultSettings.speakingVolume {
        didSet { UserDefaults.standard.set(speakingVolume, forKey: UserDefaults.speakingVolume) }
    }
}
