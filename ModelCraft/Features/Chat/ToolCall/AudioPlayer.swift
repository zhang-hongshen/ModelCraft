//
//  AudioPlayer.swift
//  ModelCraft
//
//  Created by Hongshen on 19/4/26.
//

import SwiftUI
import AVFoundation

import Waveform

struct AudioPlayer: View {
    
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
            case .loading:
                ProgressView()
            case .loaded, .idle:
                HStack(alignment: .center) {
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                    
                    Waveform(samples: SampleBuffer(samples: model.samples),
                             start: model.currentSampleTime,
                             length: Int(model.sampleRate  * windowDuration))
                        .foregroundColor(.accentColor)
                        .animation(.linear, value: model.samples.count)
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
        case loaded
        case failed(Error)
    }

    var state: LoadingState = .idle
    var isPlaying = false
    var sampleRate: Double = 200
    private var rawSampleRate: Double = 44_100
    
    var samples: [Float] = []
    
    var currentSampleTime: Int = 0
    
    private var totalDuration: TimeInterval = 0
    
    private var timer: Timer?
    
    private var task: Task<Void, Error>?
    private var player: AVAudioPlayer? = nil
    private var file: AVAudioFile? = nil
    
    deinit {
        stop()
    }
    
    func loadSamples(url: URL, maxDuration: TimeInterval = 10) async {
        stop()
        state = .loading
        
        do {
            player = try AVAudioPlayer(contentsOf: url)
            file = try AVAudioFile(forReading: url)
            loadSamples(player: player!)
            
        } catch {
            state = LoadingState.failed(error)
        }
    }
    
    func loadSamples(data: Data, mimeType: String, maxDuration: TimeInterval = 10) async {
        stop()
        state = .loading
        
        do {
            player = try AVAudioPlayer(data: data)
            guard let type = UTType(mimeType: mimeType) else {
                return
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            
            try data.write(to: tempURL, options: .atomic)
            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }
            file = try AVAudioFile(forReading: tempURL)
            loadSamples(player: player!)
            
        } catch {
            state = LoadingState.failed(error)
        }
    }
    
    
    private func loadSamples(player: AVAudioPlayer) {
        player.prepareToPlay()
        totalDuration = player.duration
        rawSampleRate = player.format.sampleRate
        self.startTimer()
        self.startSmaplingTask()
    }
    
    func startSmaplingTask() {
        guard let file = self.file else { return }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        let bufferSize = AVAudioFrameCount(format.sampleRate * 0.5)
        self.task = Task {
            while file.framePosition < frameCount || !Task.isCancelled {
                try Task.checkCancellation()
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else { break }
                try file.read(into: buffer)
                guard let channelData = buffer.floatChannelData?[0] else { continue }
                
                let frameData = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                
                self.samples.append(contentsOf: self.downsample(frameData))
                self.state = .loaded
            }
        }
    }
    
    func stopSamplingTask() {
        task?.cancel()
        self.task = nil
    }
    
    func stop() {
        stopTimer()
        samples = []
        player?.stop()
        isPlaying = false
        state = .idle
        stopSamplingTask()
        file = nil
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        stopSamplingTask()
        state = .idle
    }
    
    func play() {
        startSmaplingTask()
        player?.play()
        isPlaying = true
        startTimer()
    }
    
    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let player = self.player else { return }
            self.currentSampleTime = Int((player.currentTime / self.totalDuration) * Double(self.samples.count))
            
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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
            let peak = chunk.max(by: { abs($0) < abs($1) }) ?? 0
            result.append(peak)
            i += chunkSize
        }
        
        return result
    }
}


#Preview {
    AudioPlayer(url: PreviewResources.wav.url)
        .frame(width: 350, height: 150)
}
