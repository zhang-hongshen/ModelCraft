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
    
    @Environment(\.serverStatus) private var serverStatus
    
    @State private var isCheckingServerStatus = false
    @State private var cancellables: Set<AnyCancellable> = []
    
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
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

extension GeneralView {
    private func checkServerStatus() {
        isCheckingServerStatus = true
        OllamaClient.shared.reachable()
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
