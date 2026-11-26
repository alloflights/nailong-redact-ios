import Foundation
import CoreGraphics
import SwiftUI

#if canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif

public extension PlatformImage {
    var cgImageRepresentation: CGImage? {
        #if canImport(AppKit)
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #elseif canImport(UIKit)
        return cgImage
        #endif
    }

    static func from(cgImage: CGImage) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #elseif canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #endif
    }
}

public extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: platformImage)
        #endif
    }
}

public enum ChatPlatform: String, CaseIterable, Identifiable, Sendable {
    case auto = "微信 / QQ"
    case wechat = "微信"
    case qq = "QQ"

    public var id: String { rawValue }
}

public enum EditorToolMode: String, CaseIterable, Identifiable, Sendable {
    case swipeMosaic = "划选"
    case freeBoxMosaic = "框选"

    public var id: String { rawValue }
}

/// 归一化坐标 [0, 1]（左上角原点）的马赛克区域
public struct ManualMosaicBox: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let normalizedRect: CGRect

    public init(id: UUID = UUID(), normalizedRect: CGRect) {
        self.id = id
        self.normalizedRect = normalizedRect
    }
}

public struct AvatarColorVariant: Identifiable, Hashable, Sendable {
    public let id: Int
    public let colorName: String
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public var swiftUIColor: Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: 1.0
        )
    }

    /// 10 种与薄荷绿眼白、深棕瞳孔具有高对比度的基底色
    public static let tenVariants: [AvatarColorVariant] = [
        AvatarColorVariant(id: 0, colorName: "蓝", red: 86,  green: 89,  blue: 201),
        AvatarColorVariant(id: 1, colorName: "红", red: 224, green: 74,  blue: 92),
        AvatarColorVariant(id: 2, colorName: "黄", red: 236, green: 176, blue: 40),
        AvatarColorVariant(id: 3, colorName: "紫", red: 148, green: 84,  blue: 214),
        AvatarColorVariant(id: 4, colorName: "橙", red: 240, green: 120, blue: 52),
        AvatarColorVariant(id: 5, colorName: "粉", red: 232, green: 108, blue: 164),
        AvatarColorVariant(id: 6, colorName: "青", red: 38,  green: 166, blue: 196),
        AvatarColorVariant(id: 7, colorName: "棕", red: 168, green: 106, blue: 62),
        AvatarColorVariant(id: 8, colorName: "灰", red: 108, green: 120, blue: 136),
        AvatarColorVariant(id: 9, colorName: "绿", red: 44,  green: 128, blue: 84),
    ]
}

public struct ParticipantIdentity: Identifiable, Sendable {
    public let id: Int
    public let color: AvatarColorVariant
    public var displayName: String
    public let avatarCGImage: CGImage

    public init(id: Int, color: AvatarColorVariant, displayName: String, avatarCGImage: CGImage) {
        self.id = id
        self.color = color
        self.displayName = displayName
        self.avatarCGImage = avatarCGImage
    }
}

public enum AliasGenerator {
    public static let emotions: [String] = [
        "快乐", "开心", "呆萌", "摸鱼", "傲娇", "佛系", "元气",
        "社恐", "躺平", "迷糊", "认真", "委屈", "兴奋", "淡定"
    ]

    public static func makeParticipants(
        avatarVariants: [CGImage],
        seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) -> [ParticipantIdentity] {
        var rng = SeededRandomGenerator(seed: seed)
        let colors = AvatarColorVariant.tenVariants
        var usedNumbers = Set<String>()

        return (0..<min(10, colors.count, avatarVariants.count)).map { index in
            let emotion = emotions[Int(rng.next() % UInt64(emotions.count))]
            var numStr: String
            repeat {
                let n = 10000 + Int(rng.next() % 90000)
                numStr = String(n)
            } while usedNumbers.contains(numStr)
            usedNumbers.insert(numStr)

            let name = "\(emotion)的\(colors[index].colorName)奶龙 \(numStr)"
            return ParticipantIdentity(
                id: index,
                color: colors[index],
                displayName: name,
                avatarCGImage: avatarVariants[index]
            )
        }
    }
}

public struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x123456789ABCDEF : seed
    }

    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

public struct RedactionOptions: Sendable {
    public var platform: ChatPlatform = .auto
    public var autoNailongChat: Bool = true
    public var redactPhones: Bool = true
    public var redactIDsAndCards: Bool = true
    public var redactAccountsAndEmails: Bool = true
    public var redactMentions: Bool = true
    public var maskTopTitle: Bool = true

    public init() {}
}

public struct RedactionSummary: Sendable {
    public let detectedPlatform: ChatPlatform
    public let avatarCount: Int
    public let uniqueParticipantCount: Int
    public let nameReplacementCount: Int
    public let privacyHitCount: Int
    public let mosaicCount: Int
    public let assignedNames: [String]
}
