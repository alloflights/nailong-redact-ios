import Foundation
import CoreGraphics
import CoreText

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 生成逼真的微信 / QQ 群聊模拟截图（支持 1~10 人、含敏感隐私信息），用于无 Xcode 环境下即时预览测试
public enum SampleChatGenerator {
    private struct MockMessage {
        let userIndex: Int
        let isSelf: Bool
        let text: String
    }

    private static let mockUsers: [(name: String, qqBadge: String, color: (CGFloat, CGFloat, CGFloat), initials: String)] = [
        ("张伟",   "群主",   (0.24, 0.52, 0.90), "张"),
        ("李敏",   "管理员", (0.90, 0.36, 0.42), "李"),
        ("王强",   "LV18",   (0.92, 0.62, 0.16), "王"),
        ("陈思琪", "LV12",   (0.58, 0.38, 0.85), "陈"),
        ("赵子龙", "LV9",    (0.18, 0.68, 0.56), "赵"),
        ("刘晓峰", "冒泡",   (0.84, 0.44, 0.22), "刘"),
        ("周杰",   "LV15",   (0.28, 0.42, 0.72), "周"),
        ("吴小雨", "活跃",   (0.86, 0.38, 0.66), "吴"),
        ("林志远", "LV6",    (0.42, 0.56, 0.28), "林"),
        ("孙悦",   "LV21",   (0.38, 0.44, 0.52), "孙"),
    ]

    public static func generate(
        platform: ChatPlatform,
        participantCount: Int
    ) -> CGImage? {
        let count = max(1, min(10, participantCount))
        let isQQ = (platform == .qq)
        let width = 780
        let height = 1480
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        let W = CGFloat(width)
        let H = CGFloat(height)

        // 背景色
        let bgColor = isQQ
            ? CGColor(srgbRed: 0.945, green: 0.953, blue: 0.973, alpha: 1.0)
            : CGColor(srgbRed: 0.929, green: 0.929, blue: 0.929, alpha: 1.0)
        ctx.setFillColor(bgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // 顶部导航栏
        let navHeight: CGFloat = 136
        let navColor = isQQ
            ? CGColor(srgbRed: 0.98, green: 0.985, blue: 0.995, alpha: 1.0)
            : CGColor(srgbRed: 0.929, green: 0.929, blue: 0.929, alpha: 1.0)
        ctx.setFillColor(navColor)
        ctx.fill(CGRect(x: 0, y: H - navHeight, width: W, height: navHeight))

        // 分割线
        ctx.setFillColor(CGColor(srgbRed: 0.84, green: 0.84, blue: 0.86, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: H - navHeight, width: W, height: 1))

        // 状态栏时间
        drawText(ctx, text: "23:18", atTopLeft: CGPoint(x: 42, y: 24), imageHeight: H, fontSize: 22, weight: .semibold, color: .black)

        // 顶部返回箭头 & 群标题
        drawText(ctx, text: "‹", atTopLeft: CGPoint(x: 24, y: 74), imageHeight: H, fontSize: 36, weight: .regular, color: .black)
        let titleText = isQQ ? "产品内测交流群(\(count))" : "项目协作群(\(count))"
        drawCenteredText(ctx, text: titleText, centerX: W / 2, topY: 84, imageHeight: H, fontSize: 27, weight: .semibold, color: .black)

        // 构建覆盖 1~count 个人的消息流
        let messages = buildMessages(participantCount: count)
        var currentTopY: CGFloat = navHeight + 24

        let avatarSize: CGFloat = isQQ ? 76 : 80
        let leftMargin: CGFloat = 24
        let rightMargin: CGFloat = 24
        let maxBubbleWidth: CGFloat = 460

        for msg in messages {
            if currentTopY > H - 180 { break }
            let user = mockUsers[msg.userIndex % mockUsers.count]

            let fontSize: CGFloat = 24
            let textPaddingX: CGFloat = 22
            let textPaddingY: CGFloat = 16
            let maxTextWidth = maxBubbleWidth - textPaddingX * 2
            let measured = measureWrappedText(msg.text, fontSize: fontSize, maxWidth: maxTextWidth)
            let bubbleW = min(maxBubbleWidth, max(96, measured.width + textPaddingX * 2))
            let bubbleH = max(58, measured.height + textPaddingY * 2)

            if msg.isSelf {
                // 右侧自己
                let avatarRectTopLeft = CGRect(x: W - rightMargin - avatarSize, y: currentTopY, width: avatarSize, height: avatarSize)
                drawDummyAvatar(ctx, rectTopLeft: avatarRectTopLeft, imageHeight: H, isCircle: isQQ, color: user.color, initials: user.initials)

                let bubbleRectTopLeft = CGRect(x: avatarRectTopLeft.minX - 18 - bubbleW, y: currentTopY + 2, width: bubbleW, height: bubbleH)
                let selfBubbleColor = isQQ
                    ? CGColor(srgbRed: 0.0, green: 0.60, blue: 1.0, alpha: 1.0)
                    : CGColor(srgbRed: 0.584, green: 0.925, blue: 0.412, alpha: 1.0)
                let selfTextColor: CGColor = isQQ ? .white : .black
                fillRoundedRect(ctx, rectTopLeft: bubbleRectTopLeft, imageHeight: H, radius: isQQ ? 20 : 12, color: selfBubbleColor)
                drawWrappedText(
                    ctx,
                    text: msg.text,
                    rectTopLeft: CGRect(x: bubbleRectTopLeft.minX + textPaddingX, y: bubbleRectTopLeft.minY + textPaddingY, width: maxTextWidth, height: bubbleH - textPaddingY),
                    imageHeight: H,
                    fontSize: fontSize,
                    color: selfTextColor
                )
                currentTopY += max(avatarSize, bubbleH) + 24
            } else {
                // 左侧群友
                let avatarRectTopLeft = CGRect(x: leftMargin, y: currentTopY, width: avatarSize, height: avatarSize)
                drawDummyAvatar(ctx, rectTopLeft: avatarRectTopLeft, imageHeight: H, isCircle: isQQ, color: user.color, initials: user.initials)

                var nameStartX = avatarRectTopLeft.maxX + 18
                let nameTopY = currentTopY - 2

                if isQQ {
                    // QQ 群等级/头衔小徽章
                    let badgeW = CGFloat(user.qqBadge.count * 16 + 18)
                    let badgeRect = CGRect(x: nameStartX, y: nameTopY + 2, width: badgeW, height: 24)
                    let badgeColor = (user.qqBadge == "群主")
                        ? CGColor(srgbRed: 0.96, green: 0.68, blue: 0.20, alpha: 1.0)
                        : CGColor(srgbRed: 0.52, green: 0.66, blue: 0.96, alpha: 1.0)
                    fillRoundedRect(ctx, rectTopLeft: badgeRect, imageHeight: H, radius: 6, color: badgeColor)
                    drawText(ctx, text: user.qqBadge, atTopLeft: CGPoint(x: badgeRect.minX + 8, y: badgeRect.minY + 3), imageHeight: H, fontSize: 15, weight: .semibold, color: .white)
                    nameStartX += badgeW + 8
                }

                // 群昵称
                drawText(
                    ctx,
                    text: user.name,
                    atTopLeft: CGPoint(x: nameStartX, y: nameTopY),
                    imageHeight: H,
                    fontSize: 19,
                    weight: .regular,
                    color: CGColor(srgbRed: 0.45, green: 0.46, blue: 0.50, alpha: 1.0)
                )

                // 气泡
                let bubbleRectTopLeft = CGRect(x: avatarRectTopLeft.maxX + 18, y: currentTopY + 28, width: bubbleW, height: bubbleH)
                fillRoundedRect(ctx, rectTopLeft: bubbleRectTopLeft, imageHeight: H, radius: isQQ ? 20 : 12, color: .white)
                drawWrappedText(
                    ctx,
                    text: msg.text,
                    rectTopLeft: CGRect(x: bubbleRectTopLeft.minX + textPaddingX, y: bubbleRectTopLeft.minY + textPaddingY, width: maxTextWidth, height: bubbleH - textPaddingY),
                    imageHeight: H,
                    fontSize: fontSize,
                    color: .black
                )
                currentTopY += max(avatarSize, bubbleH + 28) + 22
            }
        }

        // 底部输入栏
        let footerH: CGFloat = 104
        ctx.setFillColor(CGColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: footerH))
        fillRoundedRect(ctx, rectTopLeft: CGRect(x: 84, y: H - footerH + 20, width: W - 210, height: 56), imageHeight: H, radius: 12, color: .white)

        return ctx.makeImage()
    }

    private static func buildMessages(participantCount: Int) -> [MockMessage] {
        let templates: [(Int, Bool, String)] = [
            (0, false, "大家好，测试手机号 13812345678 请记一下"),
            (1, false, "@张伟 收到了，我微信号 wxid_abc98765"),
            (2, false, "证件号 11010119950615231X 先放这里"),
            (9, true,  "收到，我邮箱 zhangwei@example.com 发你们"),
            (3, false, "@李敏 明天上午十点老地方见"),
            (4, false, "好的没问题，带上材料就行"),
            (5, false, "我电话也留一下 13987654321"),
            (6, false, "@陈思琪 附件已经发群邮了"),
            (7, false, "收到收到，辛苦大家！"),
            (8, false, "晚上八点准时线上碰一下进度"),
        ]
        var result: [MockMessage] = []
        for idx in 0..<participantCount {
            if idx < templates.count {
                let t = templates[idx]
                let isSelf = (idx == participantCount - 1 && participantCount >= 2)
                result.append(MockMessage(userIndex: idx, isSelf: isSelf, text: t.2))
            }
        }
        if result.count == 1 {
            result.append(MockMessage(userIndex: 0, isSelf: false, text: "单聊测试：邮箱 demo@test.cn"))
        }
        return result
    }

    // MARK: - CoreGraphics 绘制工具

    private static func toCG(_ topLeft: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(x: topLeft.minX, y: imageHeight - topLeft.maxY, width: topLeft.width, height: topLeft.height)
    }

    private static func fillRoundedRect(_ ctx: CGContext, rectTopLeft: CGRect, imageHeight: CGFloat, radius: CGFloat, color: CGColor) {
        let cgRect = toCG(rectTopLeft, imageHeight: imageHeight)
        let path = CGPath(roundedRect: cgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawDummyAvatar(
        _ ctx: CGContext,
        rectTopLeft: CGRect,
        imageHeight: CGFloat,
        isCircle: Bool,
        color: (CGFloat, CGFloat, CGFloat),
        initials: String
    ) {
        let radius = isCircle ? rectTopLeft.width / 2 : 10
        let cgColor = CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1.0)
        fillRoundedRect(ctx, rectTopLeft: rectTopLeft, imageHeight: imageHeight, radius: radius, color: cgColor)
        drawCenteredText(
            ctx,
            text: initials,
            centerX: rectTopLeft.midX,
            topY: rectTopLeft.minY + (rectTopLeft.height - 32) / 2,
            imageHeight: imageHeight,
            fontSize: 30,
            weight: .bold,
            color: .white
        )
    }

    private static func makeFont(size: CGFloat, weight: FontWeight) -> CTFont {
        #if canImport(AppKit)
        let w: NSFont.Weight = (weight == .bold) ? .bold : (weight == .semibold ? .semibold : .regular)
        return NSFont.systemFont(ofSize: size, weight: w) as CTFont
        #else
        let w: UIFont.Weight = (weight == .bold) ? .bold : (weight == .semibold ? .semibold : .regular)
        return UIFont.systemFont(ofSize: size, weight: w) as CTFont
        #endif
    }

    enum FontWeight { case regular, semibold, bold }

    private static func drawText(
        _ ctx: CGContext,
        text: String,
        atTopLeft point: CGPoint,
        imageHeight: CGFloat,
        fontSize: CGFloat,
        weight: FontWeight,
        color: CGColor
    ) {
        let font = makeFont(size: fontSize, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)

        ctx.saveGState()
        ctx.textMatrix = .identity
        let baselineY = imageHeight - point.y - ascent
        ctx.textPosition = CGPoint(x: point.x, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawCenteredText(
        _ ctx: CGContext,
        text: String,
        centerX: CGFloat,
        topY: CGFloat,
        imageHeight: CGFloat,
        fontSize: CGFloat,
        weight: FontWeight,
        color: CGColor
    ) {
        let font = makeFont(size: fontSize, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        drawText(ctx, text: text, atTopLeft: CGPoint(x: centerX - width / 2, y: topY), imageHeight: imageHeight, fontSize: fontSize, weight: weight, color: color)
    }

    private static func measureWrappedText(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CGSize {
        let font = makeFont(size: fontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attrStr.length),
            nil,
            CGSize(width: maxWidth, height: 2000),
            nil
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func drawWrappedText(
        _ ctx: CGContext,
        text: String,
        rectTopLeft: CGRect,
        imageHeight: CGFloat,
        fontSize: CGFloat,
        color: CGColor
    ) {
        let font = makeFont(size: fontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let cgRect = toCG(rectTopLeft, imageHeight: imageHeight)
        let path = CGPath(rect: cgRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attrStr.length), path, nil)

        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
