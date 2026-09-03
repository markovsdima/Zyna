//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import Foundation
import UIKit
@testable import Zyna

@Suite("BlurhashDecoder")
struct BlurhashDecoderTests {

    private func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        var remaining = value
        var digits: [Character] = []
        for _ in 0..<length {
            digits.append(Blurhash.base83Characters[remaining % 83])
            remaining /= 83
        }
        for digit in digits.reversed() {
            result.append(digit)
        }
        return result
    }

    private func firstPixel(of image: UIImage) -> (r: Int, g: Int, b: Int)? {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= 4 else {
            return nil
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    @Test("Solid colour hash decodes to that colour")
    func solidColour() throws {
        // 1×1 components: size flag 0, quantised max 0, DC = 0xFF0000 (red).
        let hash = "00" + encode83(0xFF0000, length: 4)
        let image = try #require(BlurhashDecoder.decode(hash, pixelSize: CGSize(width: 4, height: 4)))
        #expect(image.size == CGSize(width: 4, height: 4))
        let pixel = try #require(firstPixel(of: image))
        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
    }

    @Test("Reference hash decodes with 4×3 components")
    func referenceHash() throws {
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        #expect(BlurhashDecoder.components(of: hash) == BlurhashDecoder.Components(x: 4, y: 3))
        let image = try #require(BlurhashDecoder.decode(hash, pixelSize: CGSize(width: 32, height: 24)))
        #expect(image.size == CGSize(width: 32, height: 24))
    }

    @Test("Malformed hashes return nil")
    func malformed() {
        #expect(BlurhashDecoder.decode("", pixelSize: CGSize(width: 4, height: 4)) == nil)
        #expect(BlurhashDecoder.decode("LEHV6n", pixelSize: CGSize(width: 4, height: 4)) == nil)
        #expect(BlurhashDecoder.decode("!!!!!!", pixelSize: CGSize(width: 4, height: 4)) == nil)
        #expect(BlurhashDecoder.components(of: "L") == nil)
    }

    @Test("Placeholder size follows the aspect ratio")
    func placeholderSize() {
        #expect(BlurhashDecoder.placeholderSize(aspectRatio: 2, maxPixelSize: 32) == CGSize(width: 32, height: 16))
        #expect(BlurhashDecoder.placeholderSize(aspectRatio: 0.5, maxPixelSize: 32) == CGSize(width: 16, height: 32))
        #expect(BlurhashDecoder.placeholderSize(aspectRatio: nil, maxPixelSize: 32) == CGSize(width: 32, height: 32))
        #expect(BlurhashDecoder.placeholderSize(aspectRatio: 0, maxPixelSize: 32) == CGSize(width: 32, height: 32))
    }

    @Test("Placeholder is memoized")
    func placeholderMemoized() throws {
        let hash = "00" + encode83(0x00FF00, length: 4)
        let first = try #require(BlurhashDecoder.placeholder(for: hash, aspectRatio: 1))
        let second = try #require(BlurhashDecoder.placeholder(for: hash, aspectRatio: 1))
        #expect(first === second)
    }
}
