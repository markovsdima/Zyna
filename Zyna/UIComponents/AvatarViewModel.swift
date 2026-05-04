//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

struct AvatarViewModel: Equatable {

    let userId: String
    let displayName: String?
    let mxcAvatarURL: String?
    let colorOverrideHex: String?

    init(
        userId: String,
        displayName: String?,
        mxcAvatarURL: String?,
        colorOverrideHex: String? = nil
    ) {
        self.userId = userId
        self.displayName = displayName
        self.mxcAvatarURL = mxcAvatarURL
        self.colorOverrideHex = colorOverrideHex
    }

    var color: UIColor {
        if let colorOverrideHex,
           let overrideColor = UIColor.fromHexString(colorOverrideHex) {
            return overrideColor
        }
        return Self.colors[Self.stableHash(userId) % Self.colors.count]
    }

    var initials: String {
        let name = displayName ?? userId
        let cleaned = name.hasPrefix("@") ? String(name.dropFirst()) : name
        let parts = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(cleaned.prefix(2)).uppercased()
    }

    var avatarURL: URL? {
        guard let mxc = mxcAvatarURL else { return nil }
        return Self.mxcToHTTPS(mxc, size: 96)
    }

    func avatarURL(size: Int) -> URL? {
        guard let mxc = mxcAvatarURL else { return nil }
        return Self.mxcToHTTPS(mxc, size: size)
    }

    /// Pre-rendered circle with baked-in initials. Cached by userId + diameter
    /// so identical avatars share one UIImage. No cornerRadius needed, no
    /// offscreen rendering on every frame.
    func circleImage(diameter: CGFloat, fontSize: CGFloat) -> UIImage {
        let key = "\(userId):\(Int(diameter)):\(colorOverrideHex ?? "")" as NSString
        if let cached = Self.imageCache.object(forKey: key) {
            return cached
        }
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)

            color.setFill()
            UIBezierPath(ovalIn: rect).fill()

            UIColor.separator.setStroke()
            let borderPath = UIBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
            borderPath.lineWidth = 0.5
            borderPath.stroke()

            let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let text = initials as NSString
            let textSize = text.size(withAttributes: attrs)
            let textRect = CGRect(
                x: (diameter - textSize.width) / 2,
                y: (diameter - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
        }
        Self.imageCache.setObject(image, forKey: key)
        return image
    }

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    // MARK: - Private

    private static let colors: [UIColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemRed,
        .systemPurple, .systemTeal, .systemIndigo, .systemPink
    ]

    /// djb2 hash — stable across app launches, unlike `hashValue`.
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
    }

    private static func mxcToHTTPS(_ mxc: String, size: Int) -> URL? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        let path = String(mxc.dropFirst(6))
        guard let slashIndex = path.firstIndex(of: "/") else { return nil }
        let serverName = path[path.startIndex..<slashIndex]
        return URL(string: "https://\(serverName)/_matrix/media/v3/thumbnail/\(path)?width=\(size)&height=\(size)&method=crop")
    }
}
