// SPDX-License-Identifier: Apache-2.0

import Foundation
import Hub

// Copyright 2026 Sean Kammerich


/// Errors that can be returned by the H3 Evaluator.
public enum H3EvaluatorError: Error, CustomStringConvertible, Sendable {
    case frameCount(requested: Int, aligned: Int, trained: ClosedRange<Int>)
    case keyframeIndex(index: Int, frameCount: Int)
    case dimensionOffGrid(width: Int, height: Int, multiple: Int)
    case invalidRequest(rule: String, detail: String, remedy: String)
    case unreadable(path: String, reason: String)
    case mediaOffCanvas(path: String, size: String, remedy: String)
    case notImplemented(feature: String, detail: String)

    public var description: String {
        switch self {
        case let .frameCount(requested, aligned, trained):
            return "\(requested) frames align to \(aligned), outside H3's trained range "
                + "\(trained.lowerBound)–\(trained.upperBound)."
        case let .keyframeIndex(index, frameCount):
            return "keyframe \(index) is outside the \(frameCount)-frame timeline."
        case let .dimensionOffGrid(width, height, multiple):
            return "\(width)x\(height) must be a multiple of \(multiple) on both axes."
        case let .invalidRequest(rule, detail, remedy):
            return "\(rule): \(detail). Remedy: \(remedy)"
        case let .unreadable(path, reason):
            return "cannot read \(path): \(reason)"
        case let .mediaOffCanvas(path, size, remedy):
            return "\(path) is \(size), which is off the H3 canvas grid. \(remedy)"
        case let .notImplemented(feature, detail):
            return "\(feature) is not implemented: \(detail)"
        }
    }
}

extension H3EvaluatorError: LocalizedError {
    public var errorDescription: String? { description }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// Progress reported by the H3 Evaluator.
public struct H3EvaluatorProgress: Sendable {
    public enum Phase: String, Sendable, CaseIterable {
        case textConditioning
        case conditionEncoding
        case modelLoading
        case sampling
        case decoding
        case writing
    }

    public let phase: Phase
    public let completed: Int
    public let total: Int
    public let detail: String
    public let elapsed: TimeInterval

    public init(
        phase: Phase,
        completed: Int = 0,
        total: Int = 0,
        detail: String = "",
        elapsed: TimeInterval = 0
    ) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.detail = detail
        self.elapsed = elapsed
    }

    public var fraction: Double? {
        total > 0 ? Double(completed) / Double(total) : nil
    }
}

/// Cancellation shared between a UI task and the synchronous MLX sampler.
public final class H3EvaluatorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public struct H3EvaluatorCancelled: Error, CustomStringConvertible, Sendable {
    public let phase: H3EvaluatorProgress.Phase
    public let detail: String

    public init(phase: H3EvaluatorProgress.Phase, detail: String) {
        self.phase = phase
        self.detail = detail
    }

    public var description: String {
        "H3 Evaluator cancelled during \(phase.rawValue): \(detail)"
    }
}

/// The generated video and its optional side-car audio.
public struct H3EvaluatorResult: Sendable {
    public let video: URL
    public let audio: URL?
    public let frameCount: Int
    public let width: Int
    public let height: Int
    public let seconds: Double
    public let muxedAudio: Bool

    public init(
        video: URL,
        audio: URL?,
        frameCount: Int,
        width: Int,
        height: Int,
        seconds: Double,
        muxedAudio: Bool = true
    ) {
        self.video = video
        self.audio = audio
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.seconds = seconds
        self.muxedAudio = muxedAudio
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// One locally stored Ref2VA reference, kept in the order supplied by the
/// caller. The order is part of the model input: it determines the numbered
/// picture, video and audio tokens used by Ref2VA conditioning.
public enum H3Reference: Sendable, Equatable {
    case image(URL)
    case video(URL)
    case audio(URL)

    public enum Kind: String, Sendable, Equatable {
        case image
        case video
        case audio
    }

    public var kind: Kind {
        switch self {
        case .image: .image
        case .video: .video
        case .audio: .audio
        }
    }

    public var url: URL {
        switch self {
        case let .image(url), let .video(url), let .audio(url): url
        }
    }

    static func validate(_ references: [H3Reference]) throws {
        guard references.count <= 12 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "too many references",
                detail: "\(references.count) references; Ref2VA accepts at most 12",
                remedy: "provide at most 9 images, 3 videos and 3 audio clips in total.")
        }

        let images = references.filter { $0.kind == .image }.count
        let videos = references.filter { $0.kind == .video }.count
        let audio = references.filter { $0.kind == .audio }.count
        guard images <= 9 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "too many image references",
                detail: "\(images) images; Ref2VA accepts at most 9",
                remedy: "remove image references while preserving the intended order.")
        }
        guard videos <= 3 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "too many video references",
                detail: "\(videos) videos; Ref2VA accepts at most 3",
                remedy: "remove video references while preserving the intended order.")
        }
        guard audio <= 3 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "too many audio references",
                detail: "\(audio) audio clips; Ref2VA accepts at most 3",
                remedy: "remove audio references while preserving the intended order.")
        }
        guard images + videos > 0 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "audio-only references",
                detail: "Ref2VA needs at least one image or video reference",
                remedy: "include an image or video reference before generating.")
        }

        for reference in references {
            try H3IO.inspect(reference)
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// The input modes exposed by the two MiniMax H3 Base variants.
public enum H3EvaluatorInputMode: String, Codable, Sendable {
    case textToVideo = "text_to_video"
    case firstFrameToVideo = "first_frame_to_video"
    case lastFrameToVideo = "last_frame_to_video"
    case firstAndLastFrameToVideo = "first_and_last_frame_to_video"
    case referenceToVideo = "reference_to_video"
}

/// A user-supplied visual anchor on the generated timeline.
struct H3EvaluatorKeyframe: Sendable, Equatable {
    let image: URL
    let frame: Int

    init(image: URL, frame: Int) {
        self.image = image
        self.frame = frame
    }
}

/// The small, public request passed to ``H3Evaluator``.
public struct H3EvaluatorRequest: Sendable {
    public let prompt: String
    public let firstFrame: URL?
    public let lastFrame: URL?
    /// Ref2VA inputs in caller order. Their order must not be regrouped by kind.
    public let references: [H3Reference]
    public let videoOutput: URL
    public let audioOutput: URL?
    public let durationSeconds: Int
    public let width: Int
    public let height: Int
    public let steps: Int
    public let seed: UInt64

    public init(
        prompt: String,
        videoOutput: URL,
        audioOutput: URL? = nil,
        firstFrame: URL? = nil,
        lastFrame: URL? = nil,
        references: [H3Reference] = [],
        durationSeconds: Int = 5,
        width: Int = 1344,
        height: Int = 768,
        steps: Int = 20,
        seed: UInt64 = 0
    ) {
        self.prompt = prompt
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
        self.references = references
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
    }

    public var inputMode: H3EvaluatorInputMode {
        guard references.isEmpty else { return .referenceToVideo }
        switch (firstFrame != nil, lastFrame != nil) {
        case (false, false): return .textToVideo
        case (true, false): return .firstFrameToVideo
        case (false, true): return .lastFrameToVideo
        case (true, true): return .firstAndLastFrameToVideo
        }
    }

    /// The H3 Base checkpoint selected by this request's mutually exclusive inputs.
    public var task: H3Configuration.Task {
        references.isEmpty ? .fl2va : .ref2va
    }

    /// The frame count after applying H3's 17k+5 temporal lattice.
    var alignedFrameCount: Int {
        H3LatentGeometry.alignFrameCount(
            durationSeconds * H3Configuration.presetH3BaseFL2VA.frameRate,
            configuration: .presetH3BaseFL2VA)
    }

    var hasFrameConditioning: Bool {
        firstFrame != nil || lastFrame != nil
    }

    var hasReferences: Bool {
        !references.isEmpty
    }

    /// Keyframes are sorted once here so the text encoder, VAE and packed
    /// layout all consume the same image-to-time mapping.
    func resolvedKeyframes(frameCount: Int) -> [H3EvaluatorKeyframe] {
        var frames: [H3EvaluatorKeyframe] = []
        if let firstFrame {
            frames.append(H3EvaluatorKeyframe(image: firstFrame, frame: 0))
        }
        if let lastFrame {
            frames.append(H3EvaluatorKeyframe(image: lastFrame, frame: frameCount - 1))
        }
        return frames.enumerated()
            .sorted { ($0.element.frame, $0.offset) < ($1.element.frame, $1.offset) }
            .map(\.element)
    }

    func dimensions() throws -> (width: Int, height: Int) {
        guard width > 0, height > 0 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "invalid dimensions",
                detail: "\(width)x\(height)",
                remedy: "provide positive width and height values.")
        }
        guard width % 32 == 0, height % 32 == 0 else {
            throw H3EvaluatorError.dimensionOffGrid(width: width, height: height, multiple: 32)
        }
        return (width, height)
    }

    /// Performs cheap validation for the checkpoint selected by this request.
    public func validate() throws {
        try validate(for: task)
    }

    /// Performs cheap validation before the selected model's weights are loaded.
    public func validate(for task: H3Configuration.Task) throws {
        guard task == self.task else {
            throw H3EvaluatorError.invalidRequest(
                rule: "mismatched H3 Base task",
                detail: "this request selects \(self.task.rawValue), not \(task.rawValue)",
                remedy: "select the task implied by the request inputs.")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw H3EvaluatorError.invalidRequest(
                rule: "empty prompt",
                detail: "H3 Base needs a text description in every input mode",
                remedy: "describe the scene and its motion.")
        }
        guard prompt.count <= 7_000 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "prompt too long",
                detail: "\(prompt.count) characters; the limit is 7,000",
                remedy: "shorten the scene description.")
        }
        guard (5 ... 15).contains(durationSeconds) else {
            throw H3EvaluatorError.invalidRequest(
                rule: "duration out of range",
                detail: "\(durationSeconds) seconds; H3 Base is trained for 5–15 seconds",
                remedy: "use a duration between 5 and 15 seconds.")
        }
        _ = try dimensions()
        guard (1 ... 50).contains(steps) else {
            throw H3EvaluatorError.invalidRequest(
                rule: "invalid sampling steps",
                detail: "\(steps); expected 1–50",
                remedy: "use 20 steps for the default render.")
        }

        switch task {
        case .fl2va:
            for image in [firstFrame, lastFrame].compactMap({ $0 }) {
                guard FileManager.default.isReadableFile(atPath: image.path) else {
                    throw H3EvaluatorError.unreadable(
                        path: image.path,
                        reason: "image file does not exist or is not readable")
                }
            }
        case .ref2va:
            guard !hasFrameConditioning else {
                throw H3EvaluatorError.invalidRequest(
                    rule: "mixed H3 Base input variants",
                    detail: "FL2VA first/last frames cannot be combined with Ref2VA references",
                    remedy: "use first/last frames or ordered references, but not both.")
            }
            try H3Reference.validate(references)
        }

        let aligned = alignedFrameCount
        let configuration: H3Configuration = switch task {
        case .fl2va: .presetH3BaseFL2VA
        case .ref2va: .presetH3BaseRef2VA
        }
        guard configuration.minimumFrameCount...configuration.maximumFrameCount ~= aligned else {
            throw H3EvaluatorError.frameCount(
                requested: durationSeconds * configuration.frameRate,
                aligned: aligned,
                trained: configuration.minimumFrameCount...configuration.maximumFrameCount)
        }
    }
}

/// The thin entry point for MiniMax H3 Base generation.
///
/// A request with no ordered references uses H3-Base-FL2VA (including T2VA and
/// first/last-frame modes). A request with ordered references uses
/// H3-Base-Ref2VA. Conditioning and generation stay inside the selected model.
public actor H3Evaluator {
    private let fl2vaConfiguration: H3Configuration
    private let ref2vaConfiguration: H3Configuration
    private let factory = H3ModelFactory()

    public init(
        fl2vaConfiguration: H3Configuration = .presetH3BaseFL2VA,
        ref2vaConfiguration: H3Configuration = .presetH3BaseRef2VA
    ) {
        precondition(fl2vaConfiguration.task == .fl2va)
        precondition(ref2vaConfiguration.task == .ref2va)
        self.fl2vaConfiguration = fl2vaConfiguration
        self.ref2vaConfiguration = ref2vaConfiguration
    }

    @discardableResult
    public func generate(
        _ request: H3EvaluatorRequest,
        progress: @escaping (H3EvaluatorProgress) -> Void = { _ in },
        cancellation: H3EvaluatorCancellation? = nil,
        log: @escaping (String) -> Void = { _ in },
        hub: HubApi = .default
    ) async throws -> H3EvaluatorResult {
        try request.validate()
        if Task.isCancelled || cancellation?.isCancelled == true {
            throw H3EvaluatorCancelled(
                phase: .modelLoading,
                detail: "before loading \(request.task.rawValue)")
        }

        let configuration = switch request.task {
        case .fl2va: fl2vaConfiguration
        case .ref2va: ref2vaConfiguration
        }
        let modelName = configuration.modelName
        progress(H3EvaluatorProgress(
            phase: .modelLoading,
            detail: "downloading or loading \(modelName)"))

        let model = try await factory.load(configuration: configuration, hub: hub) {
            reportDownload($0, modelName: modelName, progress: progress)
        }
        return try await model.generate(
            request: request,
            progress: progress,
            cancellation: cancellation,
            log: log)
    }

    public func resetLoadedModels() async {
        await factory.reset()
    }
}

private func reportDownload(
    _ download: Progress,
    modelName: String,
    progress: (H3EvaluatorProgress) -> Void
) {
    progress(H3EvaluatorProgress(
        phase: .modelLoading,
        completed: Int(download.completedUnitCount),
        total: Int(download.totalUnitCount),
        detail: "loading \(modelName)"))
}
