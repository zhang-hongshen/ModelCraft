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

    var imageOutputDirectory = UserDefaults.standard.url(
        forKey: UserDefaults.imageOutputDirectory
    ) ?? UserDefaultSettings.imageOutputDirectory {
        didSet {
            UserDefaults.standard.set(imageOutputDirectory, forKey: UserDefaults.imageOutputDirectory)
        }
    }

    var audioOutputDirectory = UserDefaults.standard.url(
        forKey: UserDefaults.audioOutputDirectory
    ) ?? UserDefaultSettings.audioOutputDirectory {
        didSet {
            UserDefaults.standard.set(audioOutputDirectory, forKey: UserDefaults.audioOutputDirectory)
        }
    }

    var videoOutputDirectory = UserDefaults.standard.url(
        forKey: UserDefaults.videoOutputDirectory
    ) ?? UserDefaultSettings.videoOutputDirectory {
        didSet {
            UserDefaults.standard.set(videoOutputDirectory, forKey: UserDefaults.videoOutputDirectory)
        }
    }

    var customSkillDirectories = UserDefaults.standard
        .stringArray(forKey: UserDefaults.customSkillDirectories)?
        .map { URL(fileURLWithPath: $0).standardizedFileURL } ?? [] {
        didSet {
            UserDefaults.standard.set(
                customSkillDirectories.map(\.path),
                forKey: UserDefaults.customSkillDirectories
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
