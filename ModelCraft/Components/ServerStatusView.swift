//
//  ServerStatusView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 26/3/2024.
//

import SwiftUI

struct ServerStatusView: View {
    
    @Environment(\.serverStatus) private var serverStatus
    
    var body: some View {
        Label(serverStatus.wrappedValue.localizedDescription, systemImage: "circle.fill")
            .foregroundStyle({switch serverStatus.wrappedValue {
            case .disconnected: Color.red
            case .launching: Color.orange
            case .connected: Color.green
            }}())
    }
}

#Preview {
    ServerStatusView()
        .environment(\.serverStatus, .constant(ServerStatus.connected))
}
