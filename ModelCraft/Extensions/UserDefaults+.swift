//
//  UserDefaults+.swift
//  ModelCraft
//
//  Created by Hongshen on 3/2/2024.
//

import Foundation

extension UserDefaults {
    // General
    static let appearance = "appearance"
    static let language = "language"
    static let automaticallyScrollToBottom = "automaticallyScrollToBottom"
    static let modelDownloadBaseDirectory = "modelDownloadBaseDirectory"
    static let imageOutputDirectory = "imageOutputDirectory"
    static let audioOutputDirectory = "audioOutputDirectory"
    static let videoOutputDirectory = "videoOutputDirectory"
    static let customSkillDirectories = "customSkillDirectories"
    // Speaking
    static let speakingRate = "speakingRate"
    static let speakingVolume = "speakingVolume"
    
    func value<T>(forKey key: String, default defaultValue: T) -> T {
        return self.value(forKey: key) as? T ?? defaultValue
    }
    
    func append<T>(forKey key: String, newElement: T) {
        var array: [T] = value(forKey: key, default: [])
        array.append(newElement)
        setValue(array, forKey: key)
    }
}

enum UserDefaultSettings {
    static let appearance = Appearance.system
    static let automaticallyScrollToBottom = false
    static let language = Locale.defaultLanguage
    static let modelDownloadBaseDirectory = URL.applicationSupportDirectory
        .appending(path: "huggingface")
    static let imageOutputDirectory = URL.picturesDirectory
    static let audioOutputDirectory = URL.musicDirectory
    static let videoOutputDirectory = URL.moviesDirectory
    static let skillDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agents/skills")
    static let speakingRate = 0.5
    static let speakingVolume = 0.8
}

enum Appearance: String {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var id: Self { self }
}
