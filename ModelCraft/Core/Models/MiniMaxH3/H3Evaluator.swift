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


/// The generated video and its output metadata.
public struct H3EvaluatorResult: Sendable {
    public let video: URL
    public let frameCount: Int
    public let width: Int
    public let height: Int
    public let seconds: Double

    public init(
        video: URL,
        frameCount: Int,
        width: Int,
        height: Int,
        seconds: Double
    ) {
        self.video = video
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.seconds = seconds
    }
}


/// One locally stored Ref2VA reference, kept in the order supplied by the
/// caller. Media type is resolved from the URL by the evaluator and IO layer.
enum H3ReferenceMediaKind: Sendable {
    case image
    case video
    case audio
}

extension H3EvaluatorRequest {
    private func validateReferences() throws {
        guard references.count <= 12 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "too many references",
                detail: "\(references.count) references; Ref2VA accepts at most 12",
                remedy: "provide at most 9 images, 3 videos and 3 audio clips in total.")
        }

        var images = 0
        var videos = 0
        var audio = 0
        for reference in references {
            switch try H3IO.inspect(reference) {
            case .image: images += 1
            case .video: videos += 1
            case .audio: audio += 1
            }
        }
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

    }
}


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
    public let references: [URL]
    public let videoOutput: URL
    /// H3 Base resolution is fixed by the selected checkpoint configuration.
    public let duration: Int
    public let steps: Int
    public let seed: UInt64?

    public init(
        prompt: String,
        videoOutput: URL,
        firstFrame: URL? = nil,
        lastFrame: URL? = nil,
        references: [URL] = [],
        duration: Int = 5,
        steps: Int = 20,
        seed: UInt64? = nil
    ) {
        self.prompt = prompt
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
        self.references = references
        self.videoOutput = videoOutput
        self.duration = duration
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
            duration * H3Configuration.presetH3BaseFL2VA.frameRate,
            configuration: .presetH3BaseFL2VA)
    }

    var hasFrameConditioning: Bool {
        firstFrame != nil || lastFrame != nil
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

    func dimensions(for configuration: H3Configuration) throws -> (width: Int, height: Int) {
        let width = configuration.outputWidth
        let height = configuration.outputHeight
        guard width > 0, height > 0 else {
            throw H3EvaluatorError.invalidRequest(
                rule: "invalid dimensions",
                detail: "\(width)x\(height)",
                remedy: "use a valid H3 checkpoint configuration.")
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
        guard (5 ... 15).contains(duration) else {
            throw H3EvaluatorError.invalidRequest(
                rule: "duration out of range",
                detail: "\(duration) seconds; H3 Base is trained for 5–15 seconds",
                remedy: "use a duration between 5 and 15 seconds.")
        }
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
            try validateReferences()
        }

        let aligned = alignedFrameCount
        let configuration: H3Configuration = switch task {
        case .fl2va: .presetH3BaseFL2VA
        case .ref2va: .presetH3BaseRef2VA
        }
        _ = try dimensions(for: configuration)
        guard configuration.minimumFrameCount...configuration.maximumFrameCount ~= aligned else {
            throw H3EvaluatorError.frameCount(
                requested: duration * configuration.frameRate,
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

    private let factory = H3ModelFactory()

    @discardableResult
    public func generate(_ request: H3EvaluatorRequest) async throws -> H3EvaluatorResult {
        try request.validate()
        if Task.isCancelled { throw CancellationError() }

        let lease = try await InferenceRuntimeCoordinator.shared.acquire(.miniMaxH3)
        do {
        let configuration = switch request.task {
        case .fl2va: H3Configuration.presetH3BaseFL2VA
        case .ref2va: H3Configuration.presetH3BaseRef2VA
        }
        let model = try await factory.load(configuration: configuration)
        if Task.isCancelled { throw CancellationError() }
        let result = try await model.generate(request: request)
        await lease.release()
        return result
        } catch {
            await lease.release()
            throw error
        }
    }

    public func resetLoadedModels() async {
        await factory.reset()
    }
}
