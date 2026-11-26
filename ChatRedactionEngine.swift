import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct OCRItem: Identifiable, Sendable {
    public let id = UUID()
    public let text: String
    public let rectTopLeft: CGRect
}

public struct DetectedAvatar {
    public let rectTopLeft: CGRect
    public let isRightSide: Bool
    public let fingerprint: [Double]
    public var matchedNameItem: OCRItem?
    public var badgeItems: [OCRItem] = []
    public var participantSlot: Int = 0
}

public enum ChatRedactionEngine {

    public static func performOCR(on image: CGImage) -> [OCRItem] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        let observations = request.results ?? []
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)

        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let box = obs.boundingBox
            let topLeft = CGRect(
                x: box.minX * w,
                y: (1.0 - box.maxY) * h,
                width: box.width * w,
                height: box.height * h
            )
            return OCRItem(text: candidate.string, rectTopLeft: topLeft)
        }
    }

    /// 永久扁平化导出为无 EXIF/定位元数据的 PNG Data（参考 Black Highlighter 安全抹除机制）
    public static func exportFlattenedPNGData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        // 传入空属性字典，剥离 EXIF / GPS / 拍摄设备信息
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public static func redact(
        source: CGImage,
        participants: [ParticipantIdentity],
        options: RedactionOptions,
        manualBoxes: [ManualRedactionBox] = [],
        precomputedOCR: [OCRItem]? = nil
    ) -> (image: CGImage, summary: RedactionSummary)? {
        guard !participants.isEmpty else { return nil }
        let W = source.width
        let H = source.height
        let wF = CGFloat(W)
        let hF = CGFloat(H)

        let bytesPerRow = W * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: H * bytesPerRow)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let ctx = CGContext(
            data: &pixels,
            width: W,
            height: H,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: wF, height: hF))

        var detectedPlatform: ChatPlatform = options.platform
        var avatarCount = 0
        var uniqueCount = 0
        var nameReplacementCount = 0
        var privacyHitCount = 0
        var assignedNames: [String] = []

        if options.autoNailongChat {
            let ocrItems = precomputedOCR ?? performOCR(on: source)
            let chatBg = sampleChatBackground(pixels: pixels, width: W, height: H, bytesPerRow: bytesPerRow)
            var avatars = detectAvatars(pixels: pixels, width: W, height: H, bytesPerRow: bytesPerRow, chatBg: chatBg)

            detectedPlatform = resolvePlatform(
                requested: options.platform,
                ocrItems: ocrItems,
                avatars: avatars,
                pixels: pixels,
                width: W,
                height: H,
                bytesPerRow: bytesPerRow,
                chatBg: chatBg
            )

            var consumedOCRIndices = Set<Int>()
            for i in 0..<avatars.count where !avatars[i].isRightSide {
                let av = avatars[i].rectTopLeft
                let searchMinX = av.maxX + wF * 0.004
                let searchMaxX = wF * 0.72
                let searchMinY = av.minY - av.height * 0.35
                let searchMaxY = av.minY + av.height * 0.45

                var rowCandidates: [(index: Int, item: OCRItem)] = []
                for (idx, item) in ocrItems.enumerated() {
                    if consumedOCRIndices.contains(idx) { continue }
                    let r = item.rectTopLeft
                    if r.minX >= searchMinX && r.minX <= searchMaxX &&
                       r.midY >= searchMinY && r.midY <= searchMaxY &&
                       r.height < av.height * 0.65 {
                        rowCandidates.append((idx, item))
                    }
                }
                rowCandidates.sort { $0.item.rectTopLeft.minX < $1.item.rectTopLeft.minX }

                if let first = rowCandidates.first {
                    let sameRow = rowCandidates.filter {
                        abs($0.item.rectTopLeft.midY - first.item.rectTopLeft.midY) < av.height * 0.28
                    }
                    let firstIsBadge = isQQBadge(sameRow[0].item.text) ||
                        hasColoredBadgePill(pixels: pixels, width: W, height: H, bytesPerRow: bytesPerRow, rectTopLeft: sameRow[0].item.rectTopLeft, chatBg: chatBg)

                    if sameRow.count >= 2 && firstIsBadge {
                        avatars[i].badgeItems = [sameRow[0].item]
                        avatars[i].matchedNameItem = sameRow[1].item
                        consumedOCRIndices.insert(sameRow[0].index)
                        consumedOCRIndices.insert(sameRow[1].index)
                    } else {
                        avatars[i].matchedNameItem = first.item
                        consumedOCRIndices.insert(first.index)
                    }
                }
            }

            let activeCap = max(1, min(10, options.maxParticipants, participants.count))
            var keyToSlot: [String: Int] = [:]
            var fingerprintSlots: [(fingerprint: [Double], slot: Int)] = []
            var nextSlot = 0

            func assignSlot(key: String?, fingerprint: [Double]) -> Int {
                if let key = key, let existing = keyToSlot[key] {
                    return existing
                }
                if key == nil {
                    for entry in fingerprintSlots {
                        if colorDistance(entry.fingerprint, fingerprint) < 28.0 {
                            return entry.slot
                        }
                    }
                }
                let slot = nextSlot % activeCap
                nextSlot += 1
                if let key = key {
                    keyToSlot[key] = slot
                } else {
                    fingerprintSlots.append((fingerprint, slot))
                }
                return slot
            }

            var originalNameToAlias: [String: String] = [:]
            for i in 0..<avatars.count {
                let key: String? = avatars[i].isRightSide
                    ? "__SELF__"
                    : avatars[i].matchedNameItem?.text.trimmingCharacters(in: .whitespacesAndNewlines)

                let slot = assignSlot(key: key, fingerprint: avatars[i].fingerprint)
                avatars[i].participantSlot = slot

                if let cleanName = key, cleanName != "__SELF__", !cleanName.isEmpty {
                    originalNameToAlias[cleanName] = participants[slot].displayName
                }
            }

            for av in avatars {
                let identity = participants[av.participantSlot]
                let isCircle = (detectedPlatform == .qq)
                drawReplacedAvatar(
                    ctx: ctx,
                    avatarImage: identity.avatarCGImage,
                    rectTopLeft: av.rectTopLeft,
                    imageHeight: hF,
                    isCircle: isCircle
                )

                let chatBgCG = CGColor(srgbRed: chatBg.0 / 255.0, green: chatBg.1 / 255.0, blue: chatBg.2 / 255.0, alpha: 1.0)
                for badge in av.badgeItems {
                    let padRect = badge.rectTopLeft.insetBy(dx: -8, dy: -5)
                    fillTopLeftRect(ctx, rectTopLeft: padRect, imageHeight: hF, color: chatBgCG)
                }

                if let nameItem = av.matchedNameItem {
                    let startX = (av.badgeItems.first?.rectTopLeft.minX ?? nameItem.rectTopLeft.minX) - 6
                    let clearRect = CGRect(
                        x: startX,
                        y: nameItem.rectTopLeft.minY - 4,
                        width: max(nameItem.rectTopLeft.maxX - startX + 16, wF * 0.44),
                        height: nameItem.rectTopLeft.height + 8
                    )
                    let bgSample = sampleSurroundingColor(pixels: pixels, width: W, height: H, bytesPerRow: bytesPerRow, rectTopLeft: nameItem.rectTopLeft)
                    fillTopLeftRect(ctx, rectTopLeft: clearRect, imageHeight: hF, color: bgSample)

                    let textColor = contrastTextColor(for: bgSample, defaultGray: true)
                    let fontSize = max(12, min(20, nameItem.rectTopLeft.height * 0.85))
                    drawSingleLineText(
                        ctx,
                        text: identity.displayName,
                        atTopLeft: CGPoint(x: startX + 4, y: nameItem.rectTopLeft.minY),
                        imageHeight: hF,
                        fontSize: fontSize,
                        color: textColor
                    )
                    nameReplacementCount += 1
                }
            }

            if options.maskTopTitle {
                for (idx, item) in ocrItems.enumerated() {
                    if consumedOCRIndices.contains(idx) { continue }
                    let r = item.rectTopLeft
                    let inNavBand = r.minY >= hF * 0.038 && r.maxY <= hF * 0.125
                    let isCentered = abs(r.midX - wF * 0.5) < wF * 0.25 && r.width < wF * 0.65
                    let isNotTime = !isStatusBarTime(item.text)
                    if inNavBand && isCentered && isNotTime && item.text.count >= 2 {
                        let clearRect = r.insetBy(dx: -18, dy: -6)
                        let navBg = sampleSurroundingColor(pixels: pixels, width: W, height: H, bytesPerRow: bytesPerRow, rectTopLeft: r)
                        fillTopLeftRect(ctx, rectTopLeft: clearRect, imageHeight: hF, color: navBg)

                        let hasGroupCount = item.text.contains("(") || item.text.contains("（") || keyToSlot.count > 2
                        let replacementTitle: String
                        if hasGroupCount {
                            let countDisplay = max(keyToSlot.count, min(activeCap, avatars.count))
                            replacementTitle = "快乐的奶龙群(\(countDisplay))"
                        } else if let other = avatars.first(where: { !$0.isRightSide }) {
                            replacementTitle = participants[other.participantSlot].displayName
                        } else {
                            replacementTitle = participants[0].displayName
                        }

                        let textColor = contrastTextColor(for: navBg, defaultGray: false)
                        drawCenteredSingleLineText(
                            ctx,
                            text: replacementTitle,
                            centerX: wF * 0.5,
                            topY: r.minY,
                            imageHeight: hF,
                            fontSize: max(15, min(26, r.height * 0.9)),
                            color: textColor
                        )
                        consumedOCRIndices.insert(idx)
                        nameReplacementCount += 1
                        break
                    }
                }
            }

            for (idx, item) in ocrItems.enumerated() {
                if consumedOCRIndices.contains(idx) { continue }
                let text = item.text
                let r = item.rectTopLeft
                if r.minY < hF * 0.05 || r.maxY > hF * 0.93 { continue }
                if avatars.contains(where: { $0.rectTopLeft.insetBy(dx: -6, dy: -6).intersects(r) }) {
                    continue
                }

                if options.redactMentions, let mentionMatch = findStandaloneMention(in: text, knownNames: Array(originalNameToAlias.keys)) {
                    let rawName = mentionMatch.name
                    let replacementMention: String
                    if let mapped = originalNameToAlias[rawName] {
                        replacementMention = "@\(mapped)"
                    } else {
                        let fallbackSlot = abs(rawName.hashValue) % activeCap
                        replacementMention = "@\(participants[fallbackSlot].displayName)"
                    }

                    let rewrittenLine = text.replacingCharacters(in: mentionMatch.range, with: "\(replacementMention) ")
                    let bubbleBg = sampleSurroundingColor(pixels: pixels, width: W, height: H, bytesPerRow: bytesPerRow, rectTopLeft: r)
                    let bubbleMaxX = findBubbleRightEdge(pixels: pixels, width: W, height: H, bytesPerRow: bytesPerRow, startX: Int(r.maxX), y: Int(r.midY), bubbleColor: bubbleBg)
                    let clearLineRect = CGRect(x: r.minX - 4, y: r.minY - 3, width: r.width + 8, height: r.height + 6)
                    fillTopLeftRect(ctx, rectTopLeft: clearLineRect, imageHeight: hF, color: bubbleBg)

                    let tc = contrastTextColor(for: bubbleBg, defaultGray: false)
                    let baseFontSize = max(12, min(22, r.height * 0.78))
                    let availableWidth = max(r.width, CGFloat(bubbleMaxX) - r.minX - 10)
                    drawFittedSingleLineText(
                        ctx,
                        text: rewrittenLine,
                        inTopLeftRect: CGRect(x: r.minX, y: r.minY + 1, width: availableWidth, height: r.height),
                        imageHeight: hF,
                        preferredFontSize: baseFontSize,
                        color: tc
                    )
                    privacyHitCount += 1
                    continue
                }

                let sensitiveMatches = mergeRanges(findSensitiveRanges(in: text, options: options), in: text)
                for matchRange in sensitiveMatches {
                    let subRect = proportionalSubRect(of: r, fullText: text, matchRange: matchRange)
                    let pillRect = subRect.insetBy(dx: -7, dy: -3)
                    fillRoundedTopLeftRect(ctx, rectTopLeft: pillRect, imageHeight: hF, radius: 5, color: options.privacyBarColor.cgColor)
                    privacyHitCount += 1
                }
            }

            let usedSlots = Set(avatars.map { $0.participantSlot }).sorted()
            avatarCount = avatars.count
            uniqueCount = usedSlots.count
            assignedNames = usedSlots.map { participants[$0].displayName }
        }

        // 绘制 Black Highlighter 手动划选/框选的实心涂抹条
        for box in manualBoxes {
            let rectTopLeft = CGRect(
                x: box.normalizedRect.minX * wF,
                y: box.normalizedRect.minY * hF,
                width: box.normalizedRect.width * wF,
                height: box.normalizedRect.height * hF
            )
            fillRoundedTopLeftRect(ctx, rectTopLeft: rectTopLeft, imageHeight: hF, radius: 5, color: box.color.cgColor)
        }

        guard let outImage = ctx.makeImage() else { return nil }

        let summary = RedactionSummary(
            detectedPlatform: detectedPlatform,
            avatarCount: avatarCount,
            uniqueParticipantCount: uniqueCount,
            nameReplacementCount: nameReplacementCount,
            privacyHitCount: privacyHitCount,
            manualBoxCount: manualBoxes.count,
            assignedNames: assignedNames
        )
        return (outImage, summary)
    }

    // MARK: - 头像几何检测

    private static func sampleChatBackground(pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> (Double, Double, Double) {
        let x = max(2, Int(Double(width) * 0.012))
        var samples: [(Double, Double, Double)] = []
        let startY = Int(Double(height) * 0.16)
        let endY = Int(Double(height) * 0.84)
        let step = max(4, (endY - startY) / 24)
        for y in stride(from: startY, to: endY, by: step) {
            let off = y * bytesPerRow + x * 4
            samples.append((Double(pixels[off]), Double(pixels[off + 1]), Double(pixels[off + 2])))
        }
        guard !samples.isEmpty else { return (237, 237, 237) }
        let rs = samples.map(\.0).sorted()
        let gs = samples.map(\.1).sorted()
        let bs = samples.map(\.2).sorted()
        return (rs[rs.count / 2], gs[gs.count / 2], bs[bs.count / 2])
    }

    private static func detectAvatars(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        chatBg: (Double, Double, Double)
    ) -> [DetectedAvatar] {
        var found: [DetectedAvatar] = []
        let leftBand = (Int(Double(width) * 0.015), Int(Double(width) * 0.165), false)
        let rightBand = (Int(Double(width) * 0.835), Int(Double(width) * 0.985), true)

        let minY = Int(Double(height) * 0.095)
        let maxY = Int(Double(height) * 0.90)

        for (xMin, xMax, isRight) in [leftBand, rightBand] {
            let coreXMin = isRight ? Int(Double(width) * 0.855) : Int(Double(width) * 0.02)
            let coreXMax = isRight ? Int(Double(width) * 0.98) : Int(Double(width) * 0.145)

            var activeRows: [Int] = []
            for y in minY..<maxY {
                var diffCount = 0
                for x in stride(from: coreXMin, to: coreXMax, by: 2) {
                    let off = y * bytesPerRow + x * 4
                    let dist = abs(Double(pixels[off]) - chatBg.0)
                             + abs(Double(pixels[off + 1]) - chatBg.1)
                             + abs(Double(pixels[off + 2]) - chatBg.2)
                    if dist > 26 {
                        diffCount += 1
                    }
                }
                if diffCount >= max(6, (coreXMax - coreXMin) / 8) {
                    activeRows.append(y)
                }
            }

            var spans: [(Int, Int)] = []
            for y in activeRows {
                if let last = spans.last, y - last.1 <= 4 {
                    spans[spans.count - 1].1 = y
                } else {
                    spans.append((y, y))
                }
            }

            for (y0, y1) in spans {
                let h = y1 - y0 + 1
                if h < Int(Double(width) * 0.06) || h > Int(Double(width) * 0.17) { continue }

                var colCounts = [Int](repeating: 0, count: xMax - xMin)
                for x in xMin..<xMax {
                    var count = 0
                    for y in y0...y1 {
                        let off = y * bytesPerRow + x * 4
                        let dist = abs(Double(pixels[off]) - chatBg.0)
                                 + abs(Double(pixels[off + 1]) - chatBg.1)
                                 + abs(Double(pixels[off + 2]) - chatBg.2)
                        if dist > 26 { count += 1 }
                    }
                    colCounts[x - xMin] = count
                }

                let minColThreshold = max(3, Int(Double(h) * 0.25))
                var boxMinX = xMax
                var boxMaxX = xMin

                if !isRight {
                    var started = false
                    var emptyRun = 0
                    for idx in 0..<colCounts.count {
                        if colCounts[idx] >= minColThreshold {
                            if !started {
                                started = true
                                boxMinX = xMin + idx
                            }
                            boxMaxX = xMin + idx
                            emptyRun = 0
                        } else if started {
                            emptyRun += 1
                            if emptyRun >= 4 { break }
                        }
                    }
                } else {
                    var started = false
                    var emptyRun = 0
                    for idx in stride(from: colCounts.count - 1, through: 0, by: -1) {
                        if colCounts[idx] >= minColThreshold {
                            if !started {
                                started = true
                                boxMaxX = xMin + idx
                            }
                            boxMinX = xMin + idx
                            emptyRun = 0
                        } else if started {
                            emptyRun += 1
                            if emptyRun >= 4 { break }
                        }
                    }
                }

                let w = boxMaxX - boxMinX + 1
                if w < Int(Double(width) * 0.06) || w > Int(Double(width) * 0.17) { continue }
                let ratio = Double(w) / Double(h)
                if ratio < 0.72 || ratio > 1.38 { continue }

                let rect = CGRect(x: boxMinX, y: y0, width: w, height: h)
                let fp = computeAvatarFingerprint(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow, rect: rect)
                found.append(DetectedAvatar(rectTopLeft: rect, isRightSide: isRight, fingerprint: fp))
            }
        }

        found.sort { $0.rectTopLeft.minY < $1.rectTopLeft.minY }
        return found
    }

    private static func computeAvatarFingerprint(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        rect: CGRect
    ) -> [Double] {
        var fp: [Double] = []
        let grid = 4
        for gy in 0..<grid {
            for gx in 0..<grid {
                let px = min(width - 1, max(0, Int(rect.minX + rect.width * (Double(gx) + 0.5) / Double(grid))))
                let py = min(height - 1, max(0, Int(rect.minY + rect.height * (Double(gy) + 0.5) / Double(grid))))
                let off = py * bytesPerRow + px * 4
                fp.append(Double(pixels[off]))
                fp.append(Double(pixels[off + 1]))
                fp.append(Double(pixels[off + 2]))
            }
        }
        return fp
    }

    private static func colorDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 999 }
        var sum = 0.0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sqrt(sum / Double(a.count))
    }

    private static func resolvePlatform(
        requested: ChatPlatform,
        ocrItems: [OCRItem],
        avatars: [DetectedAvatar],
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        chatBg: (Double, Double, Double)
    ) -> ChatPlatform {
        if requested != .auto { return requested }

        for item in ocrItems where isQQBadge(item.text) {
            return .qq
        }
        var cornerBgHits = 0
        var cornerTotal = 0
        for av in avatars.prefix(4) {
            let r = av.rectTopLeft
            let pts = [
                (Int(r.minX) + 2, Int(r.minY) + 2),
                (Int(r.maxX) - 2, Int(r.minY) + 2),
                (Int(r.minX) + 2, Int(r.maxY) - 2),
                (Int(r.maxX) - 2, Int(r.maxY) - 2)
            ]
            for (px, py) in pts where px >= 0 && px < width && py >= 0 && py < height {
                cornerTotal += 1
                let off = py * bytesPerRow + px * 4
                let dist = abs(Double(pixels[off]) - chatBg.0)
                         + abs(Double(pixels[off + 1]) - chatBg.1)
                         + abs(Double(pixels[off + 2]) - chatBg.2)
                if dist < 24 { cornerBgHits += 1 }
            }
        }
        if cornerTotal > 0 && Double(cornerBgHits) / Double(cornerTotal) >= 0.6 {
            return .qq
        }
        return .wechat
    }

    // MARK: - 文本规则与隐私正则

    private static func isQQBadge(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["群主", "管理员", "冒泡", "活跃", "潜水"].contains(trimmed) { return true }
        return trimmed.range(of: #"^(LV|Lv|lv)\.?\s*\d{1,3}$"#, options: .regularExpression) != nil
    }

    private static func hasColoredBadgePill(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        rectTopLeft: CGRect,
        chatBg: (Double, Double, Double)
    ) -> Bool {
        let pts = [
            (Int(rectTopLeft.minX) - 3, Int(rectTopLeft.midY)),
            (Int(rectTopLeft.maxX) + 3, Int(rectTopLeft.midY)),
            (Int(rectTopLeft.midX), Int(rectTopLeft.minY) - 2)
        ]
        var coloredHits = 0
        for (px, py) in pts where px >= 0 && px < width && py >= 0 && py < height {
            let off = py * bytesPerRow + px * 4
            let r = Double(pixels[off])
            let g = Double(pixels[off + 1])
            let b = Double(pixels[off + 2])
            let dist = abs(r - chatBg.0) + abs(g - chatBg.1) + abs(b - chatBg.2)
            let saturation = max(r, max(g, b)) - min(r, min(g, b))
            if dist > 45 && saturation > 35 {
                coloredHits += 1
            }
        }
        return coloredHits >= 2
    }

    private static func isStatusBarTime(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func findStandaloneMention(
        in text: String,
        knownNames: [String]
    ) -> (range: Range<String.Index>, name: String)? {
        let sortedNames = knownNames.sorted { $0.count > $1.count }
        for name in sortedNames {
            for prefix in ["@", "＠"] {
                let target = prefix + name
                if let range = text.range(of: target) {
                    if isValidMentionBoundary(in: text, at: range.lowerBound) {
                        return (range, name)
                    }
                }
            }
        }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: #"[@＠][\p{Han}A-Za-z0-9_.\-]{1,12}"#, options: .regularExpression, range: searchStart..<text.endIndex) {
            if isValidMentionBoundary(in: text, at: range.lowerBound) {
                let name = String(text[range].dropFirst())
                return (range, name)
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func isValidMentionBoundary(in text: String, at index: String.Index) -> Bool {
        if index == text.startIndex { return true }
        let prevChar = text[text.index(before: index)]
        if prevChar.isASCII && (prevChar.isLetter || prevChar.isNumber || "._+-".contains(prevChar)) {
            return false
        }
        return true
    }

    private static func findSensitiveRanges(in text: String, options: RedactionOptions) -> [Range<String.Index>] {
        var patterns: [String] = []
        if options.redactPhones {
            patterns.append(#"(?<!\d)1[3-9]\d[-\s]?\d{4}[-\s]?\d{4}(?!\d)"#)
        }
        if options.redactIDsAndCards {
            patterns.append(#"(?<!\d)\d{17}[\dXx](?!\d)"#)
            patterns.append(#"(?<!\d)\d{13,19}(?!\d)"#)
        }
        if options.redactAccountsAndEmails {
            patterns.append(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
            patterns.append(#"wxid_[A-Za-z0-9_-]{4,}"#)
        }

        var ranges: [Range<String.Index>] = []
        for pattern in patterns {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: pattern, options: .regularExpression, range: searchStart..<text.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        return ranges
    }

    private static func mergeRanges(_ ranges: [Range<String.Index>], in text: String) -> [Range<String.Index>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [sorted[0]]
        for r in sorted.dropFirst() {
            if r.lowerBound <= merged[merged.count - 1].upperBound {
                let upper = max(merged[merged.count - 1].upperBound, r.upperBound)
                merged[merged.count - 1] = merged[merged.count - 1].lowerBound..<upper
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private static func proportionalSubRect(of fullRect: CGRect, fullText: String, matchRange: Range<String.Index>) -> CGRect {
        let totalUnits = max(1.0, visualWidthUnits(fullText))
        let prefix = String(fullText[..<matchRange.lowerBound])
        let matched = String(fullText[matchRange])
        let startFrac = visualWidthUnits(prefix) / totalUnits
        let widthFrac = visualWidthUnits(matched) / totalUnits
        return CGRect(
            x: fullRect.minX + fullRect.width * startFrac,
            y: fullRect.minY,
            width: max(18, fullRect.width * widthFrac),
            height: fullRect.height
        )
    }

    private static func visualWidthUnits(_ s: String) -> Double {
        var units = 0.0
        for scalar in s.unicodeScalars {
            if scalar.isASCII {
                if "iljtfr.,:;!| ".contains(Character(scalar)) {
                    units += 0.34
                } else if Character(scalar).isNumber || Character(scalar).isUppercase {
                    units += 0.62
                } else {
                    units += 0.54
                }
            } else {
                units += 1.0
            }
        }
        return units
    }

    private static func findBubbleRightEdge(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        startX: Int,
        y: Int,
        bubbleColor: CGColor
    ) -> Int {
        let comps = bubbleColor.components ?? [1, 1, 1, 1]
        let bR = comps[0] * 255.0
        let bG = (comps.count > 1 ? comps[1] : comps[0]) * 255.0
        let bB = (comps.count > 2 ? comps[2] : comps[0]) * 255.0
        let py = min(height - 1, max(0, y))
        var x = min(width - 1, max(0, startX))
        while x < width - 1 {
            let off = py * bytesPerRow + x * 4
            let dist = abs(Double(pixels[off]) - bR)
                     + abs(Double(pixels[off + 1]) - bG)
                     + abs(Double(pixels[off + 2]) - bB)
            if dist > 20 { break }
            x += 1
        }
        return x
    }

    // MARK: - 渲染辅助

    private static func toCG(_ topLeft: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(x: topLeft.minX, y: imageHeight - topLeft.maxY, width: topLeft.width, height: topLeft.height)
    }

    private static func drawReplacedAvatar(
        ctx: CGContext,
        avatarImage: CGImage,
        rectTopLeft: CGRect,
        imageHeight: CGFloat,
        isCircle: Bool
    ) {
        let cgRect = toCG(rectTopLeft, imageHeight: imageHeight)
        let radius = isCircle ? cgRect.width / 2.0 : max(6.0, cgRect.width * 0.12)
        let clipPath = CGPath(roundedRect: cgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.draw(avatarImage, in: cgRect)
        ctx.restoreGState()
    }

    private static func fillTopLeftRect(_ ctx: CGContext, rectTopLeft: CGRect, imageHeight: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.fill(toCG(rectTopLeft, imageHeight: imageHeight))
        ctx.restoreGState()
    }

    private static func fillRoundedTopLeftRect(_ ctx: CGContext, rectTopLeft: CGRect, imageHeight: CGFloat, radius: CGFloat, color: CGColor) {
        let cgRect = toCG(rectTopLeft, imageHeight: imageHeight)
        let path = CGPath(roundedRect: cgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func sampleSurroundingColor(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        rectTopLeft: CGRect
    ) -> CGColor {
        let pts = [
            (Int(rectTopLeft.minX) - 3, Int(rectTopLeft.midY)),
            (Int(rectTopLeft.maxX) + 3, Int(rectTopLeft.midY)),
            (Int(rectTopLeft.midX), Int(rectTopLeft.minY) - 3),
            (Int(rectTopLeft.midX), Int(rectTopLeft.maxY) + 3)
        ]
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for (px, py) in pts where px >= 0 && px < width && py >= 0 && py < height {
            let off = py * bytesPerRow + px * 4
            r += Double(pixels[off]) / 255.0
            g += Double(pixels[off + 1]) / 255.0
            b += Double(pixels[off + 2]) / 255.0
            count += 1.0
        }
        guard count > 0 else {
            return CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1.0)
        }
        return CGColor(srgbRed: r / count, green: g / count, blue: b / count, alpha: 1.0)
    }

    private static func contrastTextColor(for bg: CGColor, defaultGray: Bool) -> CGColor {
        let comps = bg.components ?? [0.9, 0.9, 0.9, 1.0]
        let r = comps[0], g = comps.count > 1 ? comps[1] : comps[0], b = comps.count > 2 ? comps[2] : comps[0]
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        if luminance < 0.52 {
            return CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        }
        return defaultGray
            ? CGColor(srgbRed: 0.45, green: 0.46, blue: 0.50, alpha: 1.0)
            : CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
    }

    private static func makeFont(size: CGFloat, bold: Bool = false) -> CTFont {
        #if canImport(AppKit)
        return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont
        #else
        return UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont
        #endif
    }

    private static func drawSingleLineText(
        _ ctx: CGContext,
        text: String,
        atTopLeft point: CGPoint,
        imageHeight: CGFloat,
        fontSize: CGFloat,
        color: CGColor
    ) {
        let font = makeFont(size: fontSize)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: point.x, y: imageHeight - point.y - ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawFittedSingleLineText(
        _ ctx: CGContext,
        text: String,
        inTopLeftRect rect: CGRect,
        imageHeight: CGFloat,
        preferredFontSize: CGFloat,
        color: CGColor
    ) {
        var fontSize = preferredFontSize
        while fontSize > 11 {
            let font = makeFont(size: fontSize)
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attr)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if w <= rect.width { break }
            fontSize -= 1.0
        }
        drawSingleLineText(ctx, text: text, atTopLeft: CGPoint(x: rect.minX, y: rect.minY), imageHeight: imageHeight, fontSize: fontSize, color: color)
    }

    private static func drawCenteredSingleLineText(
        _ ctx: CGContext,
        text: String,
        centerX: CGFloat,
        topY: CGFloat,
        imageHeight: CGFloat,
        fontSize: CGFloat,
        color: CGColor
    ) {
        let font = makeFont(size: fontSize, bold: true)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        drawSingleLineText(ctx, text: text, atTopLeft: CGPoint(x: centerX - width / 2, y: topY), imageHeight: imageHeight, fontSize: fontSize, color: color)
    }
}
