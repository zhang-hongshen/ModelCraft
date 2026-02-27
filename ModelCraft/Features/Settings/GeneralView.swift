//
//  GeneralView.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import SwiftUI

struct GeneralView: View {
    
    @State private var isCheckingServerStatus = false
    @Environment(GlobalStore.self) private var globalStore
    @Environment(UserSettings.self) private var userSettings
    
    var body: some View {
        
        @Bindable var userSettings = userSettings
        
        Form {
            Picker("Appearance", selection: $userSettings.appearance) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
            Picker("Language", selection: $userSettings.language) {
                ForEach(Bundle.main.localizations, id:\.self) { languageCode in
                    if let language = Locale(identifier: languageCode)
                        .localizedString(forLanguageCode: languageCode) {
                        Text(verbatim: language).tag(languageCode)
                    }
                }
            }

            Section {
                
                Slider(value: $userSettings.speakingRate, in: 0...1) {
                    Text("Speaking Rate")
                } minimumValueLabel: {
                    Image(systemName: "tortoise.fill")
                } maximumValueLabel: {
                    Image(systemName: "hare.fill")
                }
                
                Slider(value: $userSettings.speakingVolume, in: 0...1) {
                    Text("Speaking Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
            }
            
        }
        .formStyle(.grouped)
    }
}

#Preview {
    GeneralView()
        .environment(GlobalStore())
        .environment(UserSettings())
}
