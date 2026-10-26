//
//  UserSettings.swift
//  ModelCraft
//
//  Created by Hongshen on 26/2/25.
//

import Foundation
import SwiftUI

@MainActor
@Observable
class UserSettings {
    /// The app's one editor, shared with tools so the Settings window shows their changes.
    static let shared = UserSettings()

    var imageGenerationModelID = UserDefaults.standard.string(
        forKey: UserDefaults.imageGenerationModelID
    ) ?? "sdxl-turbo" {
        didSet {
            UserDefaults.standard.set(imageGenerationModelID, forKey: UserDefaults.imageGenerationModelID)
        }
    }

    var videoGenerationModelID = UserDefaults.standard.string(
        forKey: UserDefaults.videoGenerationModelID
    ) ?? "ltx-video" {
        didSet {
            UserDefaults.standard.set(videoGenerationModelID, forKey: UserDefaults.videoGenerationModelID)
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
    
    var loadToolsWhenNeeded: Bool = UserDefaults.standard.value(
        forKey: UserDefaults.loadToolsWhenNeeded,
        default: UserDefaultSettings.loadToolsWhenNeeded
    ) {
        didSet {
            UserDefaults.standard.set(loadToolsWhenNeeded, forKey: UserDefaults.loadToolsWhenNeeded)
        }
    }

    var notifyWhenScheduledTasksFinish: Bool = UserDefaults.standard.value(
        forKey: UserDefaults.notifyWhenScheduledTasksFinish,
        default: UserDefaultSettings.notifyWhenScheduledTasksFinish
    ) {
        didSet {
            UserDefaults.standard.set(
                notifyWhenScheduledTasksFinish,
                forKey: UserDefaults.notifyWhenScheduledTasksFinish)
        }
    }

    var appearance = UserDefaults.standard.string(forKey: UserDefaults.appearance)
        .flatMap(Appearance.init(rawValue:)) ?? UserDefaultSettings.appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: UserDefaults.appearance) }
    }

    var language = UserDefaults.standard.string(
        forKey: UserDefaults.language
    ) ?? UserDefaultSettings.language {
        didSet { UserDefaults.standard.set(language, forKey: UserDefaults.language) }
    }
}
