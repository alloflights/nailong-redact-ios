import AppIntents
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

public enum ShortcutPlatformChoice: String, AppEnum {
    case auto = "微信 / QQ"
    case wechat = "微信"
    case qq = "QQ"

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "聊天软件")
    public static let caseDisplayRepresentations: [ShortcutPlatformChoice: DisplayRepresentation] = [
        .auto: "微信 / QQ",
        .wechat: "微信",
        .qq: "QQ"
    ]
}

/// iOS 快捷指令动作：打码后直接存入手机相册，并返回无 EXIF 图像文件
public struct NailongRedactIntent: AppIntent {
    public static let title: LocalizedStringResource = "奶龙打码并存入相册"
    public static let description = IntentDescription(
        "将微信/QQ 聊天截图中的头像、昵称和敏感信息替换为多色奶龙与匿名昵称，剥离 EXIF 后直接保存到系统相册。"
    )

    @Parameter(title: "聊天截图")
    public var screenshot: IntentFile

    @Parameter(title: "聊天平台", default: .auto)
    public var platform: ShortcutPlatformChoice

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = screenshot.data
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let inputCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "NailongRedact", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取截图图像"])
        }

        guard let baseAvatar = loadBundledAvatar() else {
            throw NSError(domain: "NailongRedact", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到奶龙基础头像资源"])
        }

        let variants = AvatarRecolorEngine.generateTenVariants(from: baseAvatar)
        guard !variants.isEmpty else {
            throw NSError(domain: "NailongRedact", code: 2, userInfo: [NSLocalizedDescriptionKey: "生成头像变体失败"])
        }
        let participants = AliasGenerator.makeParticipants(avatarVariants: variants)

        var opts = RedactionOptions()
        switch platform {
        case .auto: opts.platform = .auto
        case .wechat: opts.platform = .wechat
        case .qq: opts.platform = .qq
        }

        guard let result = ChatRedactionEngine.redact(source: inputCG, participants: participants, options: opts),
              let outPNG = ChatRedactionEngine.exportFlattenedPNGData(from: result.image) else {
            throw NSError(domain: "NailongRedact", code: 3, userInfo: [NSLocalizedDescriptionKey: "打码处理失败"])
        }

        // 直接存入手机相册
        let authStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        if authStatus == .authorized || authStatus == .limited {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: outPNG, options: nil)
            }
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
                "使用\(.applicationName)给截图奶龙化并存相册"
            ],
            shortTitle: "奶龙打码存相册",
            systemImageName: "sparkles"
        )
    }
}
