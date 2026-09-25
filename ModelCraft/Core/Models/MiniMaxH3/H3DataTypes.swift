//
//  H3DataTypes.swift
//  ModelCraft
//
//  Created by Hongshen on 25/9/26.
//

import MLX

/// Latent shapes shared by the H3 Base Visual VAE, Audio VAE, sampler and DiT.
struct H3LatentGeometry: Sendable {
    let frameCount: Int
    let latentT: Int
    let audioT: Int
    let latentH: Int
    let latentW: Int
    let configuration: H3Configuration
}

/// The modality tag carried by an AdaLN row.
enum ModalityTag: Int, Sendable {
    case video = 0
    case text = 1
    case audio = 2
}

/// A kind of span in the packed H3 sequence.
enum H3SequenceSegmentKind: String, Sendable, Equatable {
    case text
    case visualCondition
    case audioCondition
    case audio
    case video

    var modality: ModalityTag {
        switch self {
        case .text: .text
        case .audio, .audioCondition: .audio
        case .video, .visualCondition: .video
        }
    }

    var isVideoStream: Bool { self == .video || self == .visualCondition }
    var isAudioStream: Bool { self == .audio || self == .audioCondition }
}

struct H3SequenceSegment: Sendable, Equatable {
    let start: Int
    let stop: Int
    let kind: H3SequenceSegmentKind

    init(start: Int, stop: Int, kind: H3SequenceSegmentKind) {
        self.start = start
        self.stop = stop
        self.kind = kind
    }

    var count: Int { stop - start }
}

struct KeyframeConfig: Sendable, Equatable {
    let resolvedFrameIndex: Int

    init(resolvedFrameIndex: Int) {
        self.resolvedFrameIndex = resolvedFrameIndex
    }
}

/// Geometry of one Ref2VA block in the user's reference order.
struct H3ReferenceSequenceBlock: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case image
        case video
        case audio
    }

    struct VisualGeometry: Sendable, Equatable {
        let latentT: Int
        let latentH: Int
        let latentW: Int
    }

    let kind: Kind
    let visual: VisualGeometry?
    let audioT: Int

    init(kind: Kind, visual: VisualGeometry? = nil, audioT: Int = 0) {
        self.kind = kind
        self.visual = visual
        self.audioT = audioT
    }
}

/// The packed sequence a DiT block sees.
struct H3Sequence: Sendable, Equatable {
    let textTokens: Int
    let audioTokens: Int
    let videoTokens: Int
    let segments: [H3SequenceSegment]
    let positionIds: [Double]
}

struct H3TextConditioningData {
    let textEmbeddings: MLXArray
    let tags: [Int]
}

struct H3Conditions {
    let videoRows: MLXArray?
    let audioRows: MLXArray?
    let keyframes: [KeyframeConfig]
    let references: [H3ReferenceSequenceBlock]
}

struct H3VisionGrid: Sendable, Equatable {
    let t: Int
    let h: Int
    let w: Int

    init(t: Int = 1, h: Int, w: Int) {
        self.t = t
        self.h = h
        self.w = w
    }

    var tokens: Int { t * h * w }
}

/// A tokenized text-and-vision input prepared by H3 Base for the H3 Encoder.
struct H3Presentation {
    struct VisionBlock {
        let merged: MLXArray
        let deepstack: [MLXArray]

        init(merged: MLXArray, deepstack: [MLXArray]) {
            self.merged = merged
            self.deepstack = deepstack
        }

        var tokens: Int { merged.dim(0) }
    }

    struct Span: Sendable, Equatable {
        let start: Int
        let size: Int
        var end: Int { start + size }
    }

    struct Assembled {
        let embeds: MLXArray
        let spans: [Span]
        let positionIds: MLXArray?
        let visualMask: MLXArray?
        let deepstack: [MLXArray]
        let tags: [Int]
    }

    enum Element {
        case tokens([Int])
        case vision(VisionBlock, H3VisionGrid)
    }

    let elements: [Element]
    let visionStartToken: Int
    let visionEndToken: Int
    let padToken: Int
}
