//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Base83 alphabet shared by the encoder (`MediaPreprocessor`) and the decoder.
enum Blurhash {

    static let base83Characters: [Character] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
    )

    private static let base83Values: [Character: Int] = {
        var values: [Character: Int] = [:]
        for (index, character) in base83Characters.enumerated() {
            values[character] = index
        }
        return values
    }()

    static func decode83<S: Sequence>(_ characters: S) -> Int? where S.Element == Character {
        var value = 0
        for character in characters {
            guard let digit = base83Values[character] else { return nil }
            value = value * 83 + digit
        }
        return value
    }
}

/// Decodes `xyz.amorgan.blurhash` strings into tiny bitmaps.
///
/// Cost is `width × height × components`, so placeholders are decoded at
/// ≤ 32 px and stretched by the renderer. Never call on the main thread for
/// anything larger than that.
enum BlurhashDecoder {

    static let defaultPlaceholderPixelSize = 32

    struct Components: Equatable {
        let x: Int
        let y: Int
    }

    private static let placeholderCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()

    static func components(of hash: String) -> Components? {
        guard let sizeFlag = Blurhash.decode83(hash.prefix(1)) else { return nil }
        let numY = sizeFlag / 9 + 1
        let numX = sizeFlag % 9 + 1
        guard hash.count == 4 + 2 * numX * numY else { return nil }
        return Components(x: numX, y: numY)
    }

    /// Memoized placeholder sized to the aspect ratio, longest side
    /// `maxPixelSize`. Returns nil for malformed hashes.
    static func placeholder(
        for hash: String,
        aspectRatio: CGFloat?,
        maxPixelSize: Int = defaultPlaceholderPixelSize
    ) -> UIImage? {
        let size = placeholderSize(aspectRatio: aspectRatio, maxPixelSize: maxPixelSize)
        let key = "\(hash)|\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = placeholderCache.object(forKey: key) {
            return cached
        }
        guard let image = decode(hash, pixelSize: size) else { return nil }
        placeholderCache.setObject(image, forKey: key)
        return image
    }

    static func placeholderSize(aspectRatio: CGFloat?, maxPixelSize: Int) -> CGSize {
        let longest = CGFloat(max(1, maxPixelSize))
        guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else {
            return CGSize(width: longest, height: longest)
        }
        if aspectRatio >= 1 {
            return CGSize(width: longest, height: max(1, (longest / aspectRatio).rounded()))
        }
        return CGSize(width: max(1, (longest * aspectRatio).rounded()), height: longest)
    }

    /// Pure decode. `punch` scales the AC components (contrast).
    static func decode(_ hash: String, pixelSize: CGSize, punch: Float = 1) -> UIImage? {
        let width = max(1, Int(pixelSize.width.rounded()))
        let height = max(1, Int(pixelSize.height.rounded()))
        guard let components = components(of: hash) else { return nil }
        let numX = components.x
        let numY = components.y
        let characters = Array(hash)

        guard let quantisedMaximumValue = Blurhash.decode83(characters[1..<2]),
              let dcValue = Blurhash.decode83(characters[2..<6]) else {
            return nil
        }
        let maximumValue = Float(quantisedMaximumValue + 1) / 166 * punch

        var colors: [SIMD3<Float>] = []
        colors.reserveCapacity(numX * numY)
        colors.append(decodeDC(dcValue))
        for index in 1..<(numX * numY) {
            let start = 4 + index * 2
            guard let acValue = Blurhash.decode83(characters[start..<(start + 2)]) else { return nil }
            colors.append(decodeAC(acValue, maximumValue: maximumValue))
        }

        var cosinesX = [Float](repeating: 0, count: width * numX)
        for x in 0..<width {
            for i in 0..<numX {
                cosinesX[x * numX + i] = cos(Float.pi * Float(x) * Float(i) / Float(width))
            }
        }
        var cosinesY = [Float](repeating: 0, count: height * numY)
        for y in 0..<height {
            for j in 0..<numY {
                cosinesY[y * numY + j] = cos(Float.pi * Float(y) * Float(j) / Float(height))
            }
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                var color = SIMD3<Float>(repeating: 0)
                for j in 0..<numY {
                    let cosineY = cosinesY[y * numY + j]
                    for i in 0..<numX {
                        color += colors[i + j * numX] * (cosinesX[x * numX + i] * cosineY)
                    }
                }
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = linearToSRGB(color.x)
                pixels[offset + 1] = linearToSRGB(color.y)
                pixels[offset + 2] = linearToSRGB(color.z)
                pixels[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                    .union(.byteOrder32Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    // MARK: - Math (inverse of MediaPreprocessor's encoder)

    private static func decodeDC(_ value: Int) -> SIMD3<Float> {
        SIMD3(
            sRGBToLinear(value >> 16),
            sRGBToLinear((value >> 8) & 255),
            sRGBToLinear(value & 255)
        )
    }

    private static func decodeAC(_ value: Int, maximumValue: Float) -> SIMD3<Float> {
        let quantisedRed = value / (19 * 19)
        let quantisedGreen = (value / 19) % 19
        let quantisedBlue = value % 19
        return SIMD3(
            signPow((Float(quantisedRed) - 9) / 9, 2) * maximumValue,
            signPow((Float(quantisedGreen) - 9) / 9, 2) * maximumValue,
            signPow((Float(quantisedBlue) - 9) / 9, 2) * maximumValue
        )
    }

    private static func signPow(_ value: Float, _ exponent: Float) -> Float {
        copysign(pow(abs(value), exponent), value)
    }

    private static func sRGBToLinear(_ value: Int) -> Float {
        let bounded = Float(max(0, min(255, value))) / 255
        if bounded <= 0.04045 {
            return bounded / 12.92
        }
        return pow((bounded + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Float) -> UInt8 {
        let bounded = max(0, min(1, value))
        let srgb: Float
        if bounded <= 0.0031308 {
            srgb = bounded * 12.92
        } else {
            srgb = 1.055 * pow(bounded, 1 / 2.4) - 0.055
        }
        return UInt8(max(0, min(255, (srgb * 255 + 0.5).rounded(.down))))
    }
}
