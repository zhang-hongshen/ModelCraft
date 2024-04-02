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
    @AppStorage(UserDefaults.showInMenuBar)
    private var showInMenuBar: Bool = true
    @AppStorage(UserDefaults.automaticallyScrollToBottom)
    private var automaticallyScrollToBottom = false
    @AppStorage(UserDefaults.language)
    private var language = Locale.defaultLanguage
    @AppStorage(UserDefaults.threadNumber)
    private var threadNumber: Int = ProcessInfo.processInfo.processorCount / 2
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
            
            Toggle("Show menu bar icon", isOn: $showInMenuBar)
            Toggle("Scroll to bottom automatically when chatting", isOn: $automaticallyScrollToBottom)
            Picker("Language", selection: $language) {
                ForEach(Bundle.main.localizations, id:\.self) { languageCode in
                    if let language = Locale(identifier: languageCode)
                        .localizedString(forLanguageCode: languageCode) {
                        Text(verbatim: language).tag(languageCode)
                    }
                }
            }
            Section {
                HStack {
                    Stepper("Thread", value: $threadNumber, in: 1...ProcessInfo.processInfo.processorCount, step: 1)
                    Text("\(threadNumber)")
                }
            } footer: {
                Text("You should modify the value according your device.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
         
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
