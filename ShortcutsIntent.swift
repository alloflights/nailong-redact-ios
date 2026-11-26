import AppIntents
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ShortcutPlatformChoice: String, AppEnum {
    case auto = "自动识别"
    case wechat = "微信"
    case qq = "QQ"

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "聊天软件")
    public static let caseDisplayRepresentations: [ShortcutPlatformChoice: DisplayRepresentation] = [
        .auto: "自动识别 (微信 / QQ)",
        .wechat: "微信",
        .qq: "QQ"
    ]
}

/// iOS 快捷指令动作：一键把最新截图中的头像与昵称换成 10 色奶龙，并打码隐私信息、抹除 EXIF
public struct NailongRedactIntent: AppIntent {
    public static let title: LocalizedStringResource = "奶龙自动打码聊天截图"
    public static let description = IntentDescription(
        "自动识别微信/QQ 聊天截图中的头像、昵称和敏感信息，替换为多色奶龙变体与匿名昵称，并剥离 EXIF 导出。"
    )

    @Parameter(title: "聊天截图")
    public var screenshot: IntentFile

    @Parameter(title: "聊天平台", default: .auto)
    public var platform: ShortcutPlatformChoice

    @Parameter(title: "最多区分人数", default: 10)
    public var maxParticipants: Int

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = screenshot.data
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let inputCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "NailongRedact", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取截图图像"])
        }

        guard let baseAvatar = loadBundledAvatar(),
              !AvatarRecolorEngine.generateTenVariants(from: baseAvatar).isEmpty else {
            throw NSError(domain: "NailongRedact", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到奶龙基础头像资源"])
        }

        let variants = AvatarRecolorEngine.generateTenVariants(from: baseAvatar)
        let participants = AliasGenerator.makeParticipants(avatarVariants: variants)

        var opts = RedactionOptions()
        opts.maxParticipants = max(1, min(10, maxParticipants))
        switch platform {
        case .auto: opts.platform = .auto
        case .wechat: opts.platform = .wechat
        case .qq: opts.platform = .qq
        }

        guard let result = ChatRedactionEngine.redact(source: inputCG, participants: participants, options: opts),
              let outPNG = ChatRedactionEngine.exportFlattenedPNGData(from: result.image) else {
            throw NSError(domain: "NailongRedact", code: 3, userInfo: [NSLocalizedDescriptionKey: "打码处理失败"])
        }

        let outFile = IntentFile(data: outPNG, filename: "nailong_redacted.png", type: .png)
        return .result(value: outFile)
    }

    private func loadBundledAvatar() -> CGImage? {
        if let url = Bundle.main.url(forResource: "avatar_base", withExtension: "jpg"),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return cg
        }
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("avatar_base.jpg")
        if let src = CGImageSourceCreateWithURL(fallback as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return cg
        }
        return nil
    }
}

public struct NailongShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NailongRedactIntent(),
            phrases: [
                "用\(.applicationName)打码聊天截图",
                "使用\(.applicationName)给截图换奶龙头像"
            ],
            shortTitle: "奶龙一键打码",
            systemImageName: "wand.and.stars"
        )
    }
}
