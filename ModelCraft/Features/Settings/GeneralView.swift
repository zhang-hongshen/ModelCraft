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
            Toggle("Scroll to bottom automatically when chatting", isOn: $userSettings.automaticallyScrollToBottom)
            
            
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
            
            
            Section {
                LabeledContent("Status") {
                    HStack {
                        ServerStatusView()
                        if isCheckingServerStatus {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Check") {
                                Task {
                                    await checkServerStatus()
                                }
                            }
                        }
                    }
                }
            }
            
        }
        .formStyle(.grouped)
    }
}

extension GeneralView {
    
    private func checkServerStatus() async {
        isCheckingServerStatus = true
        globalStore.serverStatus = await OllamaService.shared.reachable() ? .connected : .disconnected
        isCheckingServerStatus = false
    }
}

#Preview {
    GeneralView()
        .environment(GlobalStore())
        .environment(UserSettings())
}
