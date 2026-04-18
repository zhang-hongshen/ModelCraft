//
//  WanRoPE.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX

public enum WanRoPE {
    /// 3D RoPE dimension split.
    public static func ropeDimensions(headDim: Int) -> (frame: Int, height: Int, width: Int) {
        let frame = headDim - 4 * (headDim / 6)
        let height = 2 * (headDim / 6)
        let width = 2 * (headDim / 6)
        return (frame, height, width)
    }

    /// Apply 3-axis RoPE to `[B, L, N, D]`.
    public static func apply(
        _ x: MLXArray,
        grid: (f: Int, h: Int, w: Int),
        headDim: Int,
        theta: Float = 10_000
    ) -> MLXArray {
        let (f, h, w) = grid
        let dims = ropeDimensions(headDim: headDim)
        let frameDim = dims.frame
        let heightDim = dims.height
        let widthDim = dims.width

        let xFrame = x[0..., 0..<frameDim]
        let xHeight = x[0..., frameDim..<(frameDim + heightDim)]
        let xWidth = x[0..., (frameDim + heightDim)..<(frameDim + heightDim + widthDim)]

        // Frame axis RoPE
        let b = Int(x.shape[0])
        let n = Int(x.shape[2])
        let dF = frameDim
        let dH = heightDim
        let dW = widthDim

        var frame = xFrame.reshaped([b, f, h * w, n, dF]).transposed(0, 2, 3, 1, 4)
        frame = MLXFast.RoPE(frame, dimensions: dF, traditional: true, base: theta, scale: 1.0, offset: 0)
        frame = frame.transposed(0, 3, 1, 2, 4).reshaped([b, f * h * w, n, dF])

        // Height axis RoPE
        var height = xHeight.reshaped([b, f, h, w, n, dH]).transposed(0, 1, 3, 4, 2, 5)
        height = height.reshaped([b * f * w, n, h, dH])
        height = MLXFast.RoPE(height, dimensions: dH, traditional: true, base: theta, scale: 1.0, offset: 0)
        height = height.reshaped([b, f, w, n, h, dH]).transposed(0, 1, 4, 2, 3, 5)
        height = height.reshaped([b, f * h * w, n, dH])

        // Width axis RoPE
        var width = xWidth.reshaped([b, f, h, w, n, dW]).transposed(0, 1, 2, 4, 3, 5)
        width = width.reshaped([b * f * h, n, w, dW])
        width = MLXFast.RoPE(width, dimensions: dW, traditional: true, base: theta, scale: 1.0, offset: 0)
        width = width.reshaped([b, f, h, n, w, dW]).transposed(0, 1, 2, 4, 3, 5)
        width = width.reshaped([b, f * h * w, n, dW])

        return MLX.concatenated([frame, height, width], axis: -1)
    }
}
