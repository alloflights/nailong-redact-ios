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
    case auto = "自动识别"
    case wechat = "微信"
    case qq = "QQ"

    public var id: String { rawValue }
}

/// 参考 Black Highlighter 的实心多色涂抹条风格（完全不透明，无法通过调亮图片还原）
public enum RedactionColorStyle: String, CaseIterable, Identifiable, Sendable {
    case inkBlack = "墨黑"
    case pureWhite = "纯白"
    case nailongBlue = "奶龙蓝"
    case coralRed = "珊瑚红"
    case amberYellow = "琥珀黄"

    public var id: String { rawValue }

    public var swiftUIColor: Color {
        switch self {
        case .inkBlack:    return Color(red: 0.10, green: 0.11, blue: 0.14)
        case .pureWhite:   return Color.white
        case .nailongBlue: return Color(red: 86/255, green: 89/255, blue: 201/255)
        case .coralRed:    return Color(red: 224/255, green: 74/255, blue: 92/255)
        case .amberYellow: return Color(red: 236/255, green: 176/255, blue: 40/255)
        }
    }

    public var cgColor: CGColor {
        switch self {
        case .inkBlack:    return CGColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1.0)
        case .pureWhite:   return CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        case .nailongBlue: return CGColor(srgbRed: 86/255, green: 89/255, blue: 201/255, alpha: 1.0)
        case .coralRed:    return CGColor(srgbRed: 224/255, green: 74/255, blue: 92/255, alpha: 1.0)
        case .amberYellow: return CGColor(srgbRed: 236/255, green: 176/255, blue: 40/255, alpha: 1.0)
        }
    }
}

public enum EditorToolMode: String, CaseIterable, Identifiable, Sendable {
    case magicHighlighter = "魔法划选"
    case freeBox = "自由框选"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .magicHighlighter: return "highlighter"
        case .freeBox: return "rectangle.dashed"
        }
    }
}

/// 归一化坐标 [0, 1]（左上角原点）的手动打码框
public struct ManualRedactionBox: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let normalizedRect: CGRect
    public let color: RedactionColorStyle
    public let matchedOCRText: String?

    public init(
        id: UUID = UUID(),
        normalizedRect: CGRect,
        color: RedactionColorStyle,
        matchedOCRText: String? = nil
    ) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.color = color
        self.matchedOCRText = matchedOCRText
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
    public let emotion: String
    public let numberSuffix: String
    public let avatarCGImage: CGImage

    public var displayName: String {
        "\(emotion)的\(color.colorName)奶龙 \(numberSuffix)"
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

            return ParticipantIdentity(
                id: index,
                color: colors[index],
                emotion: emotion,
                numberSuffix: numStr,
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
    public var maxParticipants: Int = 10
    public var redactPhones: Bool = true
    public var redactIDsAndCards: Bool = true
    public var redactAccountsAndEmails: Bool = true
    public var redactMentions: Bool = true
    public var maskTopTitle: Bool = true
    public var privacyBarColor: RedactionColorStyle = .inkBlack

    public init() {}
}

public struct RedactionSummary: Sendable {
    public let detectedPlatform: ChatPlatform
    public let avatarCount: Int
    public let uniqueParticipantCount: Int
    public let nameReplacementCount: Int
    public let privacyHitCount: Int
    public let manualBoxCount: Int
    public let assignedNames: [String]
}
