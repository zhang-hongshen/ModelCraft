//
//  VoiceModeView.swift
//  ModelCraft
//
//  Created by Hongshen on 4/4/26.
//

import SwiftUI

struct VoiceModeView: View {
    @Binding var isPresented: Bool
    @Environment(STTService.self) private var service
    
    var body: some View {
        VStack(spacing: 40) {

            Text(service.transcript)
                .padding()
                .animation(.easeInOut, value: service.transcript)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background{
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.3))
                    .blur(radius: 60)
                    .scaleEffect(CGFloat(1.0 + service.audioLevel * 4.0))
                    .opacity(service.audioLevel > 0.05 ? 0.8 : 0.2)
                    .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.6), value: service.audioLevel)
                
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .topLeading){
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding()
        }
        .task {
            await service.startRecording()
        }
        .onDisappear {
            service.stopRecording()
        }
    }
}

#Preview {
    VoiceModeView(isPresented: .constant(true))
        .environment(STTService())
}
