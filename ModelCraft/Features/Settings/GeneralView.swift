//
//  GeneralView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import Combine

struct GeneralView: View {
    
    @State private var isCheckingServerStatus = false
    @State private var cancellables: Set<AnyCancellable> = []
    @EnvironmentObject private var globalStore: GlobalStore
    @EnvironmentObject private var userSettings: UserSettings
    
    var body: some View {
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
                            Button("Check", action: checkServerStatus)
                        }
                    }
                }
            }
            
        }
        .formStyle(.grouped)
    }
}

extension GeneralView {
    private func checkServerStatus() {
        isCheckingServerStatus = true
        OllamaService.shared.reachable()
            .sink { reachable in
                // modify environment server status
                globalStore.serverStatus = reachable ? .connected : .disconnected
                isCheckingServerStatus = false
            }
            .store(in: &cancellables)
    }
}

#Preview {
    GeneralView()
}
