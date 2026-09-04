//
//  LTXVideoRuntimeProfile.swift
//  ModelCraft
//

import Foundation

struct LTXVideoQuantization: Equatable, Sendable {
    let groupSize: Int
    let bits: Int
}

struct LTXVideoDecodeTiling: Equatable, Sendable {
    let spatialTileSize: Int
    let spatialTileStride: Int
    let sampleFrameCount: Int
    let sampleFrameStride: Int
}

struct LTXVideoRuntimeProfile: Equatable, Sendable {
    enum Tier: Equatable, Sendable {
        case survival
        case constrained
        case balanced
        case full
    }

    let tier: Tier
    let textEncoderQuantization: LTXVideoQuantization?
    let transformerQuantization: LTXVideoQuantization?
    let releasesComponentsBetweenStages: Bool
    let decodeTiling: LTXVideoDecodeTiling?

    static func recommended(physicalMemory: UInt64) -> Self {
        let gibibyte = UInt64(1024 * 1024 * 1024)

        if physicalMemory < 16 * gibibyte {
            return Self(
                tier: .survival,
                textEncoderQuantization: .init(groupSize: 64, bits: 4),
                transformerQuantization: .init(groupSize: 32, bits: 4),
                releasesComponentsBetweenStages: true,
                decodeTiling: .init(
                    spatialTileSize: 256,
                    spatialTileStride: 192,
                    sampleFrameCount: 16,
                    sampleFrameStride: 8))
        }

        if physicalMemory < 24 * gibibyte {
            return Self(
                tier: .constrained,
                textEncoderQuantization: .init(groupSize: 64, bits: 4),
                transformerQuantization: .init(groupSize: 32, bits: 8),
                releasesComponentsBetweenStages: true,
                decodeTiling: .init(
                    spatialTileSize: 256,
                    spatialTileStride: 192,
                    sampleFrameCount: 16,
                    sampleFrameStride: 8))
        }

        if physicalMemory < 48 * gibibyte {
            return Self(
                tier: .balanced,
                textEncoderQuantization: .init(groupSize: 64, bits: 8),
                transformerQuantization: nil,
                releasesComponentsBetweenStages: true,
                decodeTiling: .init(
                    spatialTileSize: 512,
                    spatialTileStride: 448,
                    sampleFrameCount: 32,
                    sampleFrameStride: 24))
        }

        return Self(
            tier: .full,
            textEncoderQuantization: nil,
            transformerQuantization: nil,
            releasesComponentsBetweenStages: false,
            decodeTiling: nil)
    }

    static var deviceDefault: Self {
        recommended(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}
