//
//  DeepSeekFlashImageProcessor.swift
//  ModelCraft
//
//  Created by Hongshen on 27/9/26.
//

import CoreGraphics
import CoreImage
import Foundation
import MLX
import MLXLMCommon

enum DeepSeekFlashImageProcessorError: Error, LocalizedError {
    case imagePlaceholderMismatch(placeholders: Int, images: Int)
    case unreadableImage
    case unsupportedVideo

    var errorDescription: String? {
        switch self {
        case .imagePlaceholderMismatch(let placeholders, let images):
            "DeepSeek Vision prompt has \(placeholders) image placeholders for \(images) images"
        case .unreadableImage:
            "DeepSeek Vision could not decode an input image"
        case .unsupportedVideo:
            "DeepSeek V4 Flash Vision Exp accepts still images, not video input"
        }
    }
}

struct DeepSeekFlashImageInput {
    let start: Int
    let patches: MLXArray
    let visionHeight: Int
    let visionWidth: Int
    let types: [Int]
    let permutation: [Int]
}

struct DeepSeekFlashPreparedInput {
    let tokenIDs: [Int]
    let images: [DeepSeekFlashImageInput]
}

enum DeepSeekFlashImageProcessor {
    private static let imageStart = 0
    private static let imagePad = 1
    private static let image = 2
    private static let imageNewline = 3
    private static let imageEnd = 4
    private static let compressAlignment = 4

    static func prepare(
        promptTokenIDs: [Int],
        images: [UserInput.Image],
        imagePlaceholderTokenID: Int,
        configuration: DeepSeekFlashConfiguration
    ) throws -> DeepSeekFlashPreparedInput {
        let placeholderCount = promptTokenIDs.reduce(0) {
            $0 + ($1 == imagePlaceholderTokenID ? 1 : 0)
        }
        guard placeholderCount == images.count else {
            throw DeepSeekFlashImageProcessorError.imagePlaceholderMismatch(
                placeholders: placeholderCount, images: images.count)
        }

        var tokens = [Int]()
        var preparedImages = [DeepSeekFlashImageInput]()
        tokens.reserveCapacity(promptTokenIDs.count + images.count * 128)
        var imageIndex = 0
        for token in promptTokenIDs {
            guard token == imagePlaceholderTokenID else {
                tokens.append(token)
                continue
            }

            let prepared = try prepareImage(
                images[imageIndex], start: tokens.count, configuration: configuration)
            preparedImages.append(prepared)
            tokens.append(contentsOf: prepared.types.map { configuration.vocabularySize + $0 })
            imageIndex += 1
        }
        return DeepSeekFlashPreparedInput(tokenIDs: tokens, images: preparedImages)
    }

    private static func prepareImage(
        _ input: UserInput.Image,
        start: Int,
        configuration: DeepSeekFlashConfiguration
    ) throws -> DeepSeekFlashImageInput {
        let ciImage = try input.asCIImage()
        let extent = ciImage.extent.integral
        let context = CIContext(options: nil)
        guard extent.width > 0, extent.height > 0,
              let source = context.createCGImage(ciImage, from: extent)
        else {
            throw DeepSeekFlashImageProcessorError.unreadableImage
        }

        let patch = configuration.visionPatchSize
        let ratio = configuration.visionDownsampleRatio
        let maximumRatio = configuration.visionMaximumWidthHeightRatio
        let originalWidth = source.width
        let originalHeight = source.height
        var width = originalWidth
        var height = originalHeight
        if width > height * maximumRatio {
            width = height * maximumRatio
        }
        if width * height < configuration.visionMinimumPixels {
            let scale = (Double(configuration.visionMinimumPixels)
                / Double(width * height)).squareRoot()
            width = Int(Double(width) * scale)
            height = Int(Double(height) * scale)
        }

        let initialWidth = ((width + patch - 1) / patch) * patch
        let initialHeight = ((height + patch - 1) / patch) * patch
        let geometry = safeResize(
            sourceHeight: height,
            sourceWidth: width,
            height: initialHeight,
            width: initialWidth,
            patchSize: patch,
            downsampleRatio: ratio,
            maximumTokenCount: configuration.visionMaximumTokenCount)
        let visionHeight = geometry.height / patch
        let visionWidth = geometry.width / patch
        let pixels = try pixels(
            source,
            width: geometry.width,
            height: geometry.height,
            stretch: originalWidth >= maximumRatio * originalHeight)
        let normalized = (pixels.asType(.float32) / 255 - 0.5) / 0.5
        let patches = normalized
            .transposed(2, 0, 1)
            .reshaped([3, visionHeight, patch, visionWidth, patch])
            .transposed(1, 3, 0, 2, 4)
            .reshaped([visionHeight * visionWidth, 3, patch, patch])
            .asType(.bfloat16)
        let block = imageBlock(
            height: geometry.languageHeight,
            width: geometry.languageWidth,
            start: start)
        return DeepSeekFlashImageInput(
            start: start,
            patches: patches,
            visionHeight: visionHeight,
            visionWidth: visionWidth,
            types: block.types,
            permutation: block.permutation)
    }

    private static func pixels(
        _ image: CGImage,
        width: Int,
        height: Int,
        stretch: Bool
    ) throws -> MLXArray {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let drawingContext = buffer.withUnsafeMutableBytes({ bytes in
            CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }) else {
            throw DeepSeekFlashImageProcessorError.unreadableImage
        }

        drawingContext.setFillColor(
            red: 127.0 / 255.0,
            green: 127.0 / 255.0,
            blue: 127.0 / 255.0,
            alpha: 1)
        drawingContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawingContext.interpolationQuality = .high
        let destination: CGRect
        if stretch {
            destination = CGRect(x: 0, y: 0, width: width, height: height)
        } else {
            let scale = min(
                CGFloat(width) / CGFloat(image.width),
                CGFloat(height) / CGFloat(image.height))
            let resizedWidth = CGFloat(image.width) * scale
            let resizedHeight = CGFloat(image.height) * scale
            destination = CGRect(
                x: (CGFloat(width) - resizedWidth) / 2,
                y: (CGFloat(height) - resizedHeight) / 2,
                width: resizedWidth,
                height: resizedHeight)
        }
        drawingContext.draw(image, in: destination)
        return MLXArray(buffer, [height, width, 4])[0..., 0..., 0 ..< 3]
    }

    private static func safeResize(
        sourceHeight: Int,
        sourceWidth: Int,
        height: Int,
        width: Int,
        patchSize: Int,
        downsampleRatio: Int,
        maximumTokenCount: Int
    ) -> (languageHeight: Int, languageWidth: Int, height: Int, width: Int) {
        let maximum = maximumTokenCount - (compressAlignment - 1)
        var result = gridTokens(
            height: height,
            width: width,
            patchSize: patchSize,
            downsampleRatio: downsampleRatio)
        var budget = maximum
        while result.tokens > maximum {
            result = solveResize(
                height: sourceHeight,
                width: sourceWidth,
                patchSize: patchSize,
                downsampleRatio: downsampleRatio,
                maximumTokenCount: budget)
            budget -= 1
        }
        return (result.languageHeight, result.languageWidth, result.height, result.width)
    }

    private static func solveResize(
        height: Int,
        width: Int,
        patchSize: Int,
        downsampleRatio: Int,
        maximumTokenCount: Int
    ) -> (languageHeight: Int, languageWidth: Int, height: Int, width: Int, tokens: Int) {
        let aspect = Double(height) / Double(width)
        let maximumWidth = (Double(maximumTokenCount - 2) / aspect + 0.25).squareRoot() - 0.5
        let maximumHeight = maximumWidth * aspect
        let bestWidth: Int
        let bestHeight: Int
        if maximumWidth < 1 {
            let languageWidth = 1
            var languageHeight = (maximumTokenCount - 2) / (languageWidth + 1)
            if languageHeight % 2 == 1 {
                languageHeight -= 1
            }
            bestWidth = languageWidth * patchSize * downsampleRatio
            bestHeight = languageHeight * patchSize * downsampleRatio
        } else if maximumHeight < 2 {
            let languageHeight = 2
            let languageWidth = (maximumTokenCount - 2) / languageHeight - 1
            bestWidth = languageWidth * patchSize * downsampleRatio
            bestHeight = languageHeight * patchSize * downsampleRatio
        } else {
            let languageWidth = Int(floor(maximumWidth))
            var languageHeight = Int(floor(maximumHeight))
            if languageHeight % 2 == 1 {
                languageHeight -= 1
            }
            let scale = min(
                Double(languageWidth * patchSize * downsampleRatio) / Double(width),
                Double(languageHeight * patchSize * downsampleRatio) / Double(height))
            bestWidth = Int(floor(Double(width) * scale / Double(patchSize))) * patchSize
            bestHeight = Int(floor(Double(height) * scale / Double(patchSize))) * patchSize
        }
        return gridTokens(
            height: bestHeight,
            width: bestWidth,
            patchSize: patchSize,
            downsampleRatio: downsampleRatio)
    }

    private static func gridTokens(
        height: Int,
        width: Int,
        patchSize: Int,
        downsampleRatio: Int
    ) -> (languageHeight: Int, languageWidth: Int, height: Int, width: Int, tokens: Int) {
        let languageHeight = ((height / patchSize) + downsampleRatio - 1) / downsampleRatio
        let languageWidth = ((width / patchSize) + downsampleRatio - 1) / downsampleRatio
        var tokens = languageHeight * (languageWidth + 1) + 2
        if languageHeight % 2 == 1 {
            tokens += languageWidth + 1
        }
        tokens += ((languageHeight + 1) / 2 * (languageWidth + 1) % 2) * 2
        return (languageHeight, languageWidth, height, width, tokens)
    }

    private static func imageBlock(
        height: Int,
        width: Int,
        start: Int
    ) -> (types: [Int], permutation: [Int]) {
        let compressionPadding = compressAlignment - 1 - start % compressAlignment
        let paddedRowCount = height + height % 2
        let rowLength = width + 1
        let finalPadding = ((paddedRowCount / 2 * rowLength) % 2) * 2

        var rowMajorTypes = [Int]()
        var rowMajorImageIndices = [Int]()
        for row in 0 ..< paddedRowCount {
            for column in 0 ..< rowLength {
                if row < height, column < width {
                    rowMajorTypes.append(image)
                    rowMajorImageIndices.append(row * width + column)
                } else if row < height {
                    rowMajorTypes.append(imageNewline)
                    rowMajorImageIndices.append(-1)
                } else {
                    rowMajorTypes.append(imagePad)
                    rowMajorImageIndices.append(-1)
                }
            }
        }

        var order = [Int]()
        for pair in 0 ..< (paddedRowCount / 2) {
            for column in 0 ..< rowLength {
                order.append((pair * 2) * rowLength + column)
                order.append((pair * 2 + 1) * rowLength + column)
            }
        }
        let orderedTypes = order.map { rowMajorTypes[$0] }
        let permutation = order.map { rowMajorImageIndices[$0] }.filter { $0 >= 0 }
        let types = Array(repeating: imagePad, count: compressionPadding)
            + [imageStart]
            + orderedTypes
            + Array(repeating: imagePad, count: finalPadding)
            + [imageEnd]
        return (types, permutation)
    }
}
