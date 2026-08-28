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
        VStack(spacing: 0) {
            switch model.state {
            case .loading:
                ProgressView()
            case .loaded, .idle:
                Waveform(samples: SampleBuffer(samples: model.samples),
                         start: model.currentSampleTime,
                         length: Int(model.sampleRate  * windowDuration))
                    .foregroundColor(.accentColor)
                    .animation(.linear, value: model.samples.count)
        
                
                HStack(alignment: .center) {
                    
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                    .imageScale(.large)
                    
                    
                    VStack(spacing: 0) {
                        Slider(
                            value: Binding(
                                get: {
                                    model.currentTime
                                },
                                set: { newTime in
                                    model.seek(to: newTime)
                                }
                            ),
                            in: 0...model.totalDuration
                        )
                        
                        HStack {
                            Text(Duration.seconds(model.currentTime).formatted())
                            Spacer()
                            Text(Duration.seconds(model.totalDuration).formatted())
                        }
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
        .padding()
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
fileprivate final class WaveformModel: NSObject, AVAudioPlayerDelegate {
    
    enum LoadingState {
        case idle
        case loading
        case loaded
        case failed(Error)
    }

    var state: LoadingState = .idle
    var isPlaying = false
    var sampleRate: Double = 200
    var samples: [Float] = []
    var currentTime: TimeInterval = 0
    var totalDuration: TimeInterval = 0
    var currentSampleTime: Int = 0
    
    private var rawSampleRate: Double = 44_100
    

    private var timer: Timer?
    
    private var task: Task<Void, Error>?
    private var player: AVAudioPlayer? = nil
    private var file: AVAudioFile? = nil
    
    deinit {
        player?.delegate = self
        stop()
    }
    
    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        isPlaying = false
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
        self.startSamplingTask()
    }
    
    func seek(to: TimeInterval) {
        player?.currentTime = to
        self.currentTime = to
        self.currentSampleTime = Int((to / self.totalDuration) * Double(self.samples.count))
    }
    
    func startSamplingTask() {
        guard let file = self.file else { return }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        let bufferSize = AVAudioFrameCount(rawSampleRate * 0.5)
        self.task = Task {
            while file.framePosition < frameCount || !Task.isCancelled {
                try Task.checkCancellation()
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else { break }
                try file.read(into: buffer)
                guard let channelData = buffer.floatChannelData?[0] else { continue }
                
                let frameData = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                
                self.samples.append(contentsOf: self.downsample(frameData, fromSampleRate: rawSampleRate, toSampleRate: sampleRate))
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
        startSamplingTask()
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
            self.currentTime = player.currentTime
            self.currentSampleTime = Int((player.currentTime / self.totalDuration) * Double(self.samples.count))
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    func downsample(
        _ input: [Float],
        fromSampleRate: Double,
        toSampleRate: Double
    ) -> [Float] {
        assert(fromSampleRate >= toSampleRate)
        let ratio = fromSampleRate / toSampleRate
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
        .frame(width: 350, height: 100)
}
