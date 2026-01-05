//
//  ServerStatusView.swift
//  ModelCraft
//
//  Created by Hongshen on 26/3/2024.
//

import SwiftUI

struct ServerStatusView: View {
    
    @Environment(GlobalStore.self) private var globalStore
    
    var body: some View {
        Label(globalStore.serverStatus.localizedDescription, systemImage: "circle.fill")
            .foregroundStyle({switch globalStore.serverStatus {
            case .disconnected: Color.red
            case .launching: Color.orange
            case .connected: Color.green
            }}())
    }
}

#Preview {
    ServerStatusView()
        .environment(GlobalStore())
}
