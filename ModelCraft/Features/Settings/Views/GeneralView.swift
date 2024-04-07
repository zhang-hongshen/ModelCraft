//
//  GeneralView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import Combine

struct GeneralView: View {
    
    @AppStorage(UserDefaults.appearance)
    private var appearance: Appearance = .system
    @AppStorage(UserDefaults.automaticallyScrollToBottom)
    private var automaticallyScrollToBottom = false
    @AppStorage(UserDefaults.language)
    private var language = Locale.defaultLanguage
    
    @AppStorage(UserDefaults.speakingRate)
    private var speakingRate = 0.5
    @AppStorage(UserDefaults.speakingVolume)
    private var speakingVolume = 0.8
    
    @State private var isCheckingServerStatus = false
    @State private var cancellables: Set<AnyCancellable> = []
    @Environment(\.serverStatus) private var serverStatus
    
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
            Picker("Language", selection: $language) {
                ForEach(Bundle.main.localizations, id:\.self) { languageCode in
                    if let language = Locale(identifier: languageCode)
                        .localizedString(forLanguageCode: languageCode) {
                        Text(verbatim: language).tag(languageCode)
                    }
                }
            }
            Toggle("Scroll to bottom automatically when chatting", isOn: $automaticallyScrollToBottom)
            
            
            Section {
                
                Slider(value: $speakingRate, in: 0...1) {
                    Text("Speaking Rate")
                } minimumValueLabel: {
                    Image(systemName: "tortoise.fill")
                } maximumValueLabel: {
                    Image(systemName: "hare.fill")
                }
                
                Slider(value: $speakingVolume, in: 0...1) {
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
                self.serverStatus.wrappedValue = reachable ? ServerStatus.connected : .disconnected
                isCheckingServerStatus = false
            }
            .store(in: &cancellables)
    }
}

#Preview {
    GeneralView()
}
