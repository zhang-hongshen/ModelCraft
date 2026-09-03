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
        @Bindable var model = model

        VStack(spacing: 0) {
            switch model.state {
            case .loading:
                ProgressView()
            case .loaded, .idle:
                Waveform(samples: model.sampleBuffer,
                         start: model.waveformStart,
                         length: Int(model.sampleRate  * windowDuration))
                    .foregroundStyle(Color.accentColor)
        
                
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
                            value: $model.playbackTime,
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
                await model.loadSamples(url: url)
            case .data(let data, let mimeType):
                await model.loadSamples(data: data, mimeType: mimeType)
            }
        }
        .onDisappear {
            model.stop()
        }
    }
    
}

@MainActor
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
    let sampleRate: Double = 200
    private(set) var sampleBuffer = SampleBuffer(samples: [0, 0, 0])
    private(set) var availableSampleCount = 0
    var currentTime: TimeInterval = 0
    var totalDuration: TimeInterval = 0

    var waveformStart: Int {
        min(Int(currentTime * sampleRate), max(availableSampleCount - 1, 0))
    }

    var playbackTime: TimeInterval {
        get { currentTime }
        set { seek(to: newValue) }
    }
    
    private var timer: Timer?
    private var samplingTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var samples: [Float] = []
    private var temporaryURL: URL?
    
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.stopTimer()
            self?.currentTime = player.duration
        }
    }
    
    func loadSamples(url: URL) async {
        stop()
        state = .loading
        
        do {
            try prepare(url: url)
        } catch {
            state = LoadingState.failed(error)
        }
    }
    
    func loadSamples(data: Data, mimeType: String) async {
        stop()
        state = .loading
        var createdTempURL: URL?
        
        do {
            guard let type = UTType(mimeType: mimeType) else {
                throw WaveformError.unsupportedAudioType
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            createdTempURL = tempURL
            try await Task.detached(priority: .utility) {
                try data.write(to: tempURL, options: .atomic)
            }.value
            try Task.checkCancellation()
            try prepare(url: tempURL)
            temporaryURL = tempURL
            createdTempURL = nil
        } catch is CancellationError {
            if let createdTempURL {
                try? FileManager.default.removeItem(at: createdTempURL)
            }
            return
        } catch {
            if let createdTempURL {
                try? FileManager.default.removeItem(at: createdTempURL)
            }
            state = LoadingState.failed(error)
        }
    }
    
    private func prepare(url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        totalDuration = player.duration
        state = .loaded
        startSampling(url: url)
    }
    
    func seek(to: TimeInterval) {
        player?.currentTime = to
        currentTime = to
    }
    
    private func startSampling(url: URL) {
        let stream = Self.sampleChunks(url: url, sampleRate: sampleRate)
        samplingTask = Task { [weak self] in
            guard let self else { return }

            do {
                var lastPublishedAt = Date.timeIntervalSinceReferenceDate
                for try await chunk in stream {
                    try Task.checkCancellation()
                    samples.append(contentsOf: chunk)

                    let now = Date.timeIntervalSinceReferenceDate
                    if now - lastPublishedAt >= 0.25 {
                        publishSamples()
                        lastPublishedAt = now
                    }
                }
                publishSamples()
            } catch is CancellationError {
                return
            } catch {
                pause()
                state = .failed(error)
            }
        }
    }
    
    private func publishSamples() {
        let displaySamples = samples.count >= 3
            ? samples
            : samples + Array(repeating: 0, count: 3 - samples.count)
        sampleBuffer = SampleBuffer(samples: displaySamples)
        availableSampleCount = samples.count
    }
    
    func stop() {
        stopTimer()
        samplingTask?.cancel()
        samplingTask = nil
        samples = []
        publishSamples()
        player?.stop()
        player = nil
        isPlaying = false
        state = .idle
        currentTime = 0
        totalDuration = 0
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
            self.temporaryURL = nil
        }
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }
    
    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration {
            seek(to: 0)
        }
        guard player.play() else { return }
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    nonisolated private static func sampleChunks(
        url: URL,
        sampleRate: Double
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .utility) {
                do {
                    let file = try AVAudioFile(forReading: url)
                    let format = file.processingFormat
                    let sourceRate = format.sampleRate
                    let bufferSize = AVAudioFrameCount(sourceRate * 0.5)
                    let framesPerSample = sourceRate / sampleRate
                    let chunkSampleCount = Int(sampleRate * 5)

                    var sourceFrame = 0
                    var nextBoundary = framesPerSample
                    var peak: Float = 0
                    var framesInPeak = 0
                    var chunk: [Float] = []
                    chunk.reserveCapacity(chunkSampleCount)

                    while file.framePosition < file.length {
                        try Task.checkCancellation()
                        guard let buffer = AVAudioPCMBuffer(
                            pcmFormat: format,
                            frameCapacity: bufferSize
                        ) else {
                            break
                        }
                        try file.read(into: buffer)
                        guard let channelData = buffer.floatChannelData else { continue }

                        for frame in 0 ..< Int(buffer.frameLength) {
                            for channel in 0 ..< Int(format.channelCount) {
                                let value = channelData[channel][frame]
                                if abs(value) > abs(peak) {
                                    peak = value
                                }
                            }

                            sourceFrame += 1
                            framesInPeak += 1
                            if Double(sourceFrame) >= nextBoundary {
                                chunk.append(peak)
                                peak = 0
                                framesInPeak = 0
                                nextBoundary += framesPerSample

                                if chunk.count == chunkSampleCount {
                                    continuation.yield(chunk)
                                    chunk.removeAll(keepingCapacity: true)
                                }
                            }
                        }
                    }

                    if framesInPeak > 0 {
                        chunk.append(peak)
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                worker.cancel()
            }
        }
    }
}

private enum WaveformError: LocalizedError {
    case unsupportedAudioType

    var errorDescription: String? {
        String(localized: "Unsupported audio type")
    }
}


#Preview {
    AudioPlayer(url: PreviewResources.wav.url)
        .frame(width: 350, height: 100)
}
