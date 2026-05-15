//
//  WaveformView.swift
//  ModelCraft
//
//  Created by Hongshen on 19/4/26.
//

import SwiftUI
import AVFoundation

import Waveform

struct WaveformView: View {
    
    private let source: Source
    let windowDuration: TimeInterval = 5.0
    
    @State private var model = WaveformModel()
    @State private var start = 0
    
    private enum Source: Hashable {
        case url(URL)
        case data(Data, mimeType: String)
    }
    
    
    init(url: URL) {
        self.source = .url(url)
    }
    
    init(data: Data, mimeType: String) {
        self.source = .data(data, mimeType: mimeType)
    }
    
    var body: some View {
        VStack {
            switch model.state {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView()
            case .loaded(let samples):
                HStack(alignment: .center) {
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                    
                    Waveform(samples: samples,
                             start: start,
                             length: Int(windowDuration * model.sampleRate))
                        .foregroundColor(.accentColor)
                        .animation(.linear, value: samples.count)
                        .overlay {
                            Rectangle()
                                .fill(.red)
                                .frame(width: 2)
                        }
                        .onChange(of: samples.count) {
                            let halfWindowSamples = Int((windowDuration / 2) * model.sampleRate)
                            start = max(0, Int(model.sampleTime) - halfWindowSamples)
                        }
                }
                
                
            case .failed(let error):
                ContentUnavailableView {
                    Label("Failed to Load Waveform", systemImage: "waveform.path.badge.minus")
                } description: {
                    Text(error.localizedDescription)
                }
            }
        }
        .task(id: source) {
            switch source {
            case .url(let url):
                await model.loadSamples(url: url, maxDuration: windowDuration)
            case .data(let data, let mimeType):
                await model.loadSamples(data: data, mimeType: mimeType, maxDuration: windowDuration)
            }
        }
    }
    
}

@Observable
final class WaveformModel {
    
    enum LoadingState {
        case idle
        case loading
        case loaded(SampleBuffer)
        case failed(Error)
    }

    var state: LoadingState = .idle
    var isPlaying = false
    var sampleRate: Double = 400
    var sampleTime: AVAudioFramePosition = 0
    var rawSampleRate: Double = 44_100
    var rawSampleTime: AVAudioFramePosition = 0
    
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var timer: Timer?
    private var samples: [Float] = []
    private var task: Task<Void, Error>?
    
    init() {
        engine.attach(playerNode)
    }
    
    deinit {
        stop()
    }
    
    func loadSamples(url: URL, maxDuration: TimeInterval = 10) async {
        stop()
        await MainActor.run { state = .loading }
        self.task = Task.detached(priority: .userInitiated) {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                self.rawSampleRate = format.sampleRate
                let frameCount = AVAudioFrameCount(file.length)
                
                self.engine.connect(self.playerNode, to: self.engine.mainMixerNode, format: format)
                try self.engine.start()
                
                self.playerNode.scheduleFile(file, at: nil, completionHandler: nil)
                self.playerNode.play()
                self.isPlaying = true
                self.startTimer()
                
                let bufferSize = AVAudioFrameCount(format.sampleRate * 0.1)
                let maxCount = Int(self.sampleRate * maxDuration)
                
                while file.framePosition < frameCount {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else { break }
                    try file.read(into: buffer)
                    
                    if let channelData = buffer.floatChannelData?[0] {
                        let frameData = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                        
                        self.samples.append(contentsOf: self.downsample(frameData))
                        
                        if self.samples.count > maxCount ||
                            file.framePosition >= frameCount{
//                            self.samples.removeFirst(self.samples.count - maxCount)
                            await MainActor.run {
                                self.state = .loaded(SampleBuffer(samples: self.samples))
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.state = LoadingState.failed(error) }
            }
        }
    }
    
    func loadSamples(data: Data, mimeType: String, maxDuration: TimeInterval = 10) async {
        guard let type = UTType(mimeType: mimeType) else {
            return
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
        
        do {
            try data.write(to: tempURL, options: .atomic)
            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }
            await self.loadSamples(url: tempURL, maxDuration: maxDuration)
            
        } catch {
            self.state = .failed(error)
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        playerNode.stop()
        engine.stop()
        isPlaying = false
        samples = []
        sampleTime = 0
        rawSampleTime = 0
        if let task  {
            task.cancel()
            self.task = nil
        }
    }
    
    func togglePlay() {
        if playerNode.isPlaying {
            playerNode.pause()
        } else {
            playerNode.play()
        }
        isPlaying = playerNode.isPlaying
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if let nodeTime = self.playerNode.lastRenderTime,
               let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) {
                
                self.rawSampleTime = playerTime.sampleTime
                self.sampleTime = AVAudioFramePosition(Double(playerTime.sampleTime) * self.sampleRate / self.rawSampleRate)
                
            }
        }
    }
    
    func downsample(
        _ input: [Float]
    ) -> [Float] {
        
        let ratio = rawSampleRate / sampleRate
        let chunkSize = max(1, Int(ratio))
        
        var result: [Float] = []
        result.reserveCapacity(input.count / chunkSize)
        
        var i = 0
        
        while i < input.count {
            let end = min(i + chunkSize, input.count)
            let chunk = input[i..<end]
            let peak = chunk.map { abs($0) }.max() ?? 0
            result.append(peak)
            i += chunkSize
        }
        
        return result
    }
}
