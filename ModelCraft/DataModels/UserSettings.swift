//
//  UserSettings.swift
//  ModelCraft
//
//  Created by Hongshen on 2/26/25.
//

import Foundation
import SwiftUI

class UserSettings: ObservableObject {
    
    @AppStorage(UserDefaults.appearance)
    var appearance: Appearance = .system
    @AppStorage(UserDefaults.automaticallyScrollToBottom)
    var automaticallyScrollToBottom = false
    @AppStorage(UserDefaults.language)
    var language = Locale.defaultLanguage
    
    @AppStorage(UserDefaults.speakingRate)
    var speakingRate = 0.5
    @AppStorage(UserDefaults.speakingVolume)
    var speakingVolume = 0.8
    
}
