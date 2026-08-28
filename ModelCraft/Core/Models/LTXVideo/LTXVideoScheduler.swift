//
//  LTXVideoScheduler.swift
//  ModelCraft
//

import Foundation

import MLX

public struct LTXVideoFlowMatchEulerScheduler {
    public let numTrainTimesteps: Int
    public let baseImageSequenceLength: Int
    public let maxImageSequenceLength: Int
    public let baseShift: Float
    public let maxShift: Float
    public let shiftTerminal: Float

    public private(set) var timesteps: [Float] = []
    private var sigmas: [Float] = []

    public init(
        numTrainTimesteps: Int = 1000,
        baseImageSequenceLength: Int = 1024,
        maxImageSequenceLength: Int = 4096,
        baseShift: Float = 0.95,
        maxShift: Float = 2.05,
        shiftTerminal: Float = 0.1
    ) {
        self.numTrainTimesteps = numTrainTimesteps
        self.baseImageSequenceLength = baseImageSequenceLength
        self.maxImageSequenceLength = maxImageSequenceLength
        self.baseShift = baseShift
        self.maxShift = maxShift
        self.shiftTerminal = shiftTerminal
    }

    public mutating func setTimesteps(stepCount: Int, sequenceLength: Int) {
        let mu = calculateShift(sequenceLength: sequenceLength)
        let start: Float = 1.0
        let end: Float = 1.0 / Float(stepCount)

        var values: [Float] = []
        for index in 0..<stepCount {
            let t = stepCount == 1 ? Float(0) : Float(index) / Float(stepCount - 1)
            let sigma = start + (end - start) * t
            values.append(timeShift(mu: mu, sigma: sigma))
        }

        if let last = values.last, last > shiftTerminal {
            let scale = shiftTerminal / last
            values = values.map { $0 * scale }
        }

        self.sigmas = values + [0]
        self.timesteps = values.map { $0 * Float(numTrainTimesteps) }
    }

    public func step(modelOutput: MLXArray, stepIndex: Int, sample: MLXArray) -> MLXArray {
        let sigma = sigmas[stepIndex]
        let sigmaNext = sigmas[stepIndex + 1]
        return sample + (sigmaNext - sigma) * modelOutput
    }

    private func calculateShift(sequenceLength: Int) -> Float {
        let x1 = Float(baseImageSequenceLength)
        let x2 = Float(maxImageSequenceLength)
        let y1 = baseShift
        let y2 = maxShift
        let m = (y2 - y1) / (x2 - x1)
        let b = y1 - m * x1
        return m * Float(sequenceLength) + b
    }

    private func timeShift(mu: Float, sigma: Float) -> Float {
        let expMu = exp(mu)
        return expMu / (expMu + (1.0 / sigma - 1.0))
    }
}

public enum LTXVideoLatentPacker {
    public static func pack(_ latents: MLXArray, patchSize: Int = 1, patchSizeT: Int = 1) -> MLXArray {
        let b = Int(latents.shape[0])
        let f = Int(latents.shape[1])
        let h = Int(latents.shape[2])
        let w = Int(latents.shape[3])
        let c = Int(latents.shape[4])
        let pf = f / patchSizeT
        let ph = h / patchSize
        let pw = w / patchSize

        return latents
            .reshaped([b, pf, patchSizeT, ph, patchSize, pw, patchSize, c])
            .transposed(0, 1, 3, 5, 7, 2, 4, 6)
            .reshaped([b, pf * ph * pw, c * patchSizeT * patchSize * patchSize])
    }

    public static func unpack(
        _ latents: MLXArray,
        frameCount: Int,
        height: Int,
        width: Int,
        patchSize: Int = 1,
        patchSizeT: Int = 1
    ) -> MLXArray {
        let b = Int(latents.shape[0])
        return latents
            .reshaped([b, frameCount, height, width, -1, patchSizeT, patchSize, patchSize])
            .transposed(0, 1, 5, 2, 6, 3, 7, 4)
            .reshaped([b, frameCount * patchSizeT, height * patchSize, width * patchSize, -1])
    }
}

