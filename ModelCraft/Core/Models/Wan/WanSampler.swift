//
//  WanSampler.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX

private func lambda64(alpha: MLXArray, sigma: MLXArray) -> MLXArray {
    let a = alpha.asType(.float64)
    let s = sigma.asType(.float64)
    return (MLX.log(a) - MLX.log(s)).asType(.float32)
}

public struct FlowUniPCMultistepScheduler {
    public let numTrainTimesteps: Int
    public let solverOrder: Int
    public let predictionType: String
    public let shift: Float
    public var predictX0: Bool
    public var solverType: String
    public var lowerOrderFinal: Bool
    public let disableCorrector: [Int]
    public let finalSigmasType: String
    
    private let sigmaMin: Float
    private let sigmaMax: Float
    
    public private(set) var sigmas: MLXArray
    public private(set) var timesteps: MLXArray
    public private(set) var numInferenceSteps: Int
    public private(set) var stepIndex: Int

    public var modelOutputs: [MLXArray?]
    public var timestepList: [MLXArray?]
    public var lowerOrderNums: Int = 0
    public var lastSample: MLXArray? = nil
    public var thisOrder: Int = 1

    public init(
            numTrainTimesteps: Int = 1000,
            solverOrder: Int = 2,
            predictionType: String = "flow_prediction",
            shift: Float = 1.0,
            predictX0: Bool = true,
            solverType: String = "bh2",
            lowerOrderFinal: Bool = true,
            disableCorrector: [Int] = [],
            finalSigmasType: String = "zero"
        ) {
            self.numTrainTimesteps = numTrainTimesteps
            self.solverOrder = solverOrder
            self.predictionType = predictionType
            self.shift = shift
            self.predictX0 = predictX0
            self.solverType = solverType
            self.lowerOrderFinal = lowerOrderFinal
            self.disableCorrector = disableCorrector
            self.finalSigmasType = finalSigmasType
            
            
            var sigmas = MLX.linspace(1.0 - Float(1.0 / Float(numTrainTimesteps)), Float(0) , count: numTrainTimesteps)
            sigmas = (shift * sigmas) / (1.0 + (shift - 1.0) * sigmas)
            
            
            self.sigmaMin = sigmas[sigmas.shape[0] - 1].item(Float.self)
            self.sigmaMax = sigmas[0].item(Float.self)
            
            self.sigmas = MLXArray([Float32]())
            self.timesteps = MLXArray([Float32]())
            self.numInferenceSteps = 0
            self.modelOutputs = Array(repeating: nil, count: solverOrder)
            self.timestepList = Array(repeating: nil, count: solverOrder)
            self.lastSample = nil
            self.stepIndex = 0
        }

    public mutating func setTimesteps(_ steps: Int, shift: Float? = nil) {
        
        var sigmas = MLX.linspace(self.sigmaMax, self.sigmaMin, count: steps + 1)[0..<steps]
        
        let shift = shift ?? self.shift
        sigmas = (shift * sigmas) / (1.0 + (shift - 1.0) * sigmas)
        
        self.timesteps = sigmas * numTrainTimesteps
        
        self.sigmas = MLX.concatenated([sigmas, MLXArray([Float(0.0)])], axis: 0).asType(.float32)
        
        self.numInferenceSteps = steps
        self.modelOutputs = Array(repeating: nil, count: solverOrder)
        self.lowerOrderNums = 0
        self.lastSample = nil
        self.stepIndex = 0
    }

    private func sigmaToAlphaSigma(_ sigma: MLXArray) -> (MLXArray, MLXArray) {
        (1.0 - sigma, sigma)
    }

    private func convertModelOutput(_ modelOutput: MLXArray, sample: MLXArray) -> MLXArray {
        let sigmaT = sigmas[stepIndex]
        return predictX0 ? sample - sigmaT * modelOutput : sample - (1.0 - sigmaT) * modelOutput
    }

    private func indexForTimestep(_ timestep: MLXArray, scheduleTimesteps: MLXArray? = nil) -> Int {
        let sTimesteps = scheduleTimesteps ?? self.timesteps
        let timestepVal = timestep.asType(sTimesteps.dtype)
        let diff = MLX.abs(sTimesteps - timestepVal)
        let firstIdx = MLX.argMin(diff)
        let numMatches = MLX.sum(diff .== 0).item(Int.self)
        if numMatches > 1 {
            return firstIdx.item(Int.self) + 1
        }
        return firstIdx.item(Int.self)
    }

    private mutating func initStepIndex(_ timestep: MLXArray) {
        self.stepIndex = indexForTimestep(timestep)
    }

    private func multistepPredictor(modelOutput: MLXArray, sample: MLXArray, order: Int) -> MLXArray {
        guard let m0 = modelOutputs[solverOrder - 1] else { return sample }
        let sigmaT = sigmas[stepIndex + 1]
        let sigmaS0 = sigmas[stepIndex]
        let (alphaT, sigmaT2) = sigmaToAlphaSigma(sigmaT)
        let (alphaS0, sigmaS02) = sigmaToAlphaSigma(sigmaS0)
        let lambdaT = lambda64(alpha: alphaT, sigma: sigmaT2)
        let lambdaS0 = lambda64(alpha: alphaS0, sigma: sigmaS02)
        let h = lambdaT - lambdaS0
        let hphi1 = MLX.expm1(predictX0 ? -h : h)
        return predictX0
            ? (sigmaT2 / sigmaS02) * sample - alphaT * hphi1 * m0
            : (alphaT / alphaS0) * sample - sigmaT2 * hphi1 * m0
    }

    private func multistepCorrector(
        thisModelOutput: MLXArray,
        lastSample: MLXArray,
        thisSample: MLXArray,
        order: Int
    ) -> MLXArray {
        let m0 = modelOutputs.last!!
        let x = lastSample
        var xT = thisSample
        let modelT = thisModelOutput

        let sigmaTVal = self.sigmas[self.stepIndex]
        let sigmaS0Val = self.sigmas[self.stepIndex - 1]
        
        let (alphaT, sigmaT) = self.sigmaToAlphaSigma(sigmaTVal)
        let (alphaS0, sigmaS0) = self.sigmaToAlphaSigma(sigmaS0Val)

        let lambdaT = lambda64(alpha: alphaT, sigma: sigmaT)
        let lambdaS0 = lambda64(alpha: alphaS0, sigma: sigmaS0)
        let h = lambdaT - lambdaS0

        var rks: [MLXArray] = []
        var D1s: [MLXArray] = []
        
        for i in 1..<order {
            let si = self.stepIndex - (i + 1)
            let mi = modelOutputs[modelOutputs.count - (i + 1)]!
            
            let (alphaSi, sigmaSi) = self.sigmaToAlphaSigma(self.sigmas[si])
            let lambdaSi = lambda64(alpha: alphaSi, sigma: sigmaSi)
            
            let rk = (lambdaSi - lambdaS0) / h
            rks.append(rk)
            
            D1s.append((mi - m0) / rk)
        }

        rks.append(MLXArray(1.0).asType(.float32))
        let rksStacked = MLX.stacked(rks)

        var R_rows: [MLXArray] = []
        var b_vals: [MLXArray] = []
        
        let hh = self.predictX0 ? -h : h
        let hPhi1 = MLX.expm1(hh)
        var hPhiK = hPhi1 / hh - 1
        var factorialI: Float = 1.0

        let Bh: MLXArray
        if self.solverType == "bh1" {
            Bh = hh
        } else {
            Bh = MLX.expm1(hh)
        }

        for i in 1...order {
            R_rows.append(rksStacked ** Float(i - 1))
            b_vals.append(hPhiK * factorialI / Bh)
            
            factorialI *= Float(i + 1)
            hPhiK = hPhiK / hh - 1.0 / factorialI
        }

        let R = MLX.stacked(R_rows)
        let b = MLX.stacked(b_vals)

        var rhosC: MLXArray
        if order == 1 {
            rhosC = MLXArray([0.5]).asType(x.dtype)
        } else {
            rhosC = MLX.MLXLinalg.solve(R, b, stream: .cpu).asType(x.dtype)
        }
        
        let D1_t = modelT - m0
        let D1sStacked = D1s.isEmpty ? nil : MLX.stacked(D1s, axis: 1)
        
        
        var corrRes: MLXArray = MLXArray(0.0).asType(x.dtype)
        if let D1sMatrix = D1sStacked {
            let rhosSlice = rhosC[0..<rhosC.count-1]
            let reshapedRhos = rhosSlice.reshaped([-1] + Array(repeating: 1, count: D1sMatrix.ndim - 1))
            corrRes = (reshapedRhos * D1sMatrix).sum(axis: 1)
        }
        
        if self.predictX0 {
            let xT_ = (sigmaT / sigmaS0) * x - alphaT * hPhi1 * m0
            xT = xT_ - alphaT * Bh * (corrRes + rhosC[rhosC.count - 1] * D1_t)
        } else {
            let xT_ = (alphaT / alphaS0) * x - sigmaT * hPhi1 * m0
            xT = xT_ - sigmaT * Bh * (corrRes + rhosC[rhosC.count - 1] * D1_t)
        }

        return xT.asType(x.dtype)
    }
    public mutating func step(modelOutput: MLXArray, timestep: MLXArray, sample: MLXArray) -> MLXArray {
        if stepIndex == nil { initStepIndex(timestep) }

        let userCorrector = stepIndex > 0 && self.disableCorrector.contains(stepIndex - 1) && lastSample != nil
        let modelOutputConverted = convertModelOutput(modelOutput, sample: sample)
        if stepIndex > 0, let _ = lastSample {
            // Corrector path omitted for compactness; predictor remains stable.
        }

        for i in 0..<(solverOrder - 1) {
            modelOutputs[i] = modelOutputs[i + 1]
            timestepList[i] = timestepList[i + 1]
        }
        modelOutputs[solverOrder - 1] = modelOutputConverted
        timestepList[solverOrder - 1] = timestep
        
        let candidateOrder = lowerOrderFinal
            ? min(solverOrder, timesteps.count - stepIndex)
            : solverOrder
        thisOrder = min(candidateOrder, lowerOrderNums + 1)

        lastSample = sample
        let prevSample = multistepPredictor(modelOutput: modelOutput, sample: sample, order: max(1, thisOrder))
        if lowerOrderNums < solverOrder { lowerOrderNums += 1 }
        stepIndex += 1
        return prevSample
    }
}

public struct FlowEulerDiscreteScheduler {
    public let numTrainTimesteps: Int
    public private(set) var timesteps: MLXArray = MLXArray([Float32]())
    public private(set) var sigmas: MLXArray = MLXArray([Float32]())
    public private(set) var numInferenceSteps: Int = 0

    public init(numTrainTimesteps: Int = 1000) {
        self.numTrainTimesteps = numTrainTimesteps
    }

    public mutating func setTimesteps(_ denoisingStepList: [Int], shift: Float = 5.0) {
        var sigmas = MLX.linspace(Float(1.0), Float(0.0), count: numTrainTimesteps + 1)[0..<numTrainTimesteps]
        sigmas = shift * sigmas / (1.0 + (shift - 1.0) * sigmas)
        let timesteps = sigmas * numTrainTimesteps

        let indices = denoisingStepList.map { numTrainTimesteps - $0 }
        self.sigmas = MLXArray(indices.map { Float32(sigmas[$0].item(Float.self)) })
        self.timesteps = MLXArray(indices.map { Float32(timesteps[$0].item(Float.self)) })
        self.numInferenceSteps = denoisingStepList.count
    }

    public mutating func step(modelOutput: MLXArray, timestep: MLXArray, sample: MLXArray) -> MLXArray {
        let diff = MLX.abs(timesteps.asType(.float32) - timestep.asType(.float32))
        let step_index = Int(MLX.argMin(diff).item(Int32.self))
        let sigma = self.sigmas[step_index]
        let sigmaNext = step_index < numInferenceSteps - 1 ? sigmas[step_index + 1] : MLXArray(Float32(0))
        return sample + modelOutput * (sigmaNext - sigma)
    }
}
