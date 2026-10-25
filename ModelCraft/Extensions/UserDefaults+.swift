//
//  UserDefaults+.swift
//  ModelCraft
//
//  Created by Hongshen on 3/2/24.
//

import Foundation

extension UserDefaults {
    // General
    static let appearance = "appearance"
    static let language = "language"
    static let automaticallyScrollToBottom = "automaticallyScrollToBottom"
    static let customSkillDirectories = "customSkillDirectories"
    static let imageGenerationModelID = "imageGenerationModelID"
    static let videoGenerationModelID = "videoGenerationModelID"
    static let loadToolsWhenNeeded = "loadToolsWhenNeeded"
    static let holidayRegion = "holidayRegion"
    static let notifyWhenScheduledTasksFinish = "notifyWhenScheduledTasksFinish"
    static let toolPermissionMode = "toolPermissionMode"
    
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
    static let loadToolsWhenNeeded = true
    static let holidayRegion = Locale.current.region?.identifier ?? ""
    static let notifyWhenScheduledTasksFinish = false
    static let toolPermissionMode = ToolPermissionMode.acceptEdits
    static let language = Locale.defaultLanguage
    static let modelDownloadBaseDirectory = URL.applicationSupportDirectory
        .appending(path: "ModelCraft")
    static let skillDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agents/skills")
}

enum Appearance: String {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var id: Self { self }
}
