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
            WaveformView(level: service.audioLevel)

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

struct WaveformView: View {
    var level: Float
    private let numberOfBars = 12

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<numberOfBars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor)
                    .frame(width: 4, height: calculateHeight(for: i))
                    .animation(.spring(response: 0.15, dampingFraction: 0.5), value: level)
            }
        }
    }

    private func calculateHeight(for index: Int) -> CGFloat {
        let normalizedLevel = CGFloat(sqrt(max(0, level)))

        let center = Double(numberOfBars - 1) / 2.0
        let distFromCenter = abs(Double(index) - center)
        let modifier = max(0.2, 1.0 - (distFromCenter / center))
        
        let minH: CGFloat = 10
        let maxH: CGFloat = 80
        
        return minH + (maxH - minH) * normalizedLevel * CGFloat(modifier)
    }
}

#Preview {
    VoiceModeView(isPresented: .constant(true))
        .environment(STTService())
}
