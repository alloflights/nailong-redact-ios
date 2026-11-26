import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct FlattenedPNGTransfer: Transferable {
    public let data: Data

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.data
        }
    }
}

@MainActor
public final class RedactStudioViewModel: ObservableObject {
    public enum MockSourceMode: String, CaseIterable, Identifiable {
        case wechat = "微信群聊"
        case qq = "QQ群聊"
        case custom = "我的截图"
        public var id: String { rawValue }
    }

    public enum DrawerPanel: String, Equatable {
        case none
        case colors
        case nailongSettings
    }

    @Published public var sourceMode: MockSourceMode = .wechat
    @Published public var toolMode: EditorToolMode = .magicHighlighter
    @Published public var activeBarColor: RedactionColorStyle = .inkBlack
    @Published public var activeDrawer: DrawerPanel = .none

    @Published public var options = RedactionOptions()
    @Published public var baseAvatarCG: CGImage?
    @Published public var participants: [ParticipantIdentity] = []

    @Published public var sourceCG: CGImage?
    @Published public var ocrItems: [OCRItem] = []
    @Published public var manualBoxes: [ManualRedactionBox] = []
    @Published public var redactedCG: CGImage?
    @Published public var summary: RedactionSummary?

    @Published public var isPeekingOriginal = false
    @Published public var toastMessage: String?

    @Published public var selectedPhotoItem: PhotosPickerItem?

    @Published public var dragPoints: [CGPoint] = []
    @Published public var freeDragOrigin: CGPoint?
    @Published public var freeDragCurrent: CGPoint?

    private var avatarVariants: [CGImage] = []
    private var importedCustomCG: CGImage?

    public init() {
        loadBaseAvatar()
        if !avatarVariants.isEmpty {
            participants = AliasGenerator.makeParticipants(avatarVariants: avatarVariants)
        }
        loadSample(for: .wechat)
    }

    public func loadBaseAvatar() {
        var candidates: [URL] = []
        if let bundleURL = Bundle.main.url(forResource: "avatar_base", withExtension: "jpg") {
            candidates.append(bundleURL)
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("avatar_base.jpg"))
        candidates.append(URL(fileURLWithPath: "/Users/cliqueychen/Desktop/code/ChatRedactPreview/avatar_base.jpg"))

        for url in candidates {
            if let img = Self.loadCGImage(at: url) {
                baseAvatarCG = img
                avatarVariants = AvatarRecolorEngine.generateTenVariants(from: img)
                return
            }
        }
    }

    public func switchSource(_ mode: MockSourceMode) {
        sourceMode = mode
        manualBoxes.removeAll()
        switch mode {
        case .wechat:
            options.platform = .wechat
            loadSample(for: .wechat)
        case .qq:
            options.platform = .qq
            loadSample(for: .qq)
        case .custom:
            options.platform = .auto
            if let importedCustomCG {
                setSourceImage(importedCustomCG)
            }
        }
    }

    public func loadSample(for platform: ChatPlatform) {
        if let cg = SampleChatGenerator.generate(platform: platform, participantCount: options.maxParticipants) {
            setSourceImage(cg)
        }
    }

    public func setSourceImage(_ cg: CGImage) {
        sourceCG = cg
        ocrItems = ChatRedactionEngine.performOCR(on: cg)
        reprocess()
    }

    public func importImage(from url: URL) {
        guard let cg = Self.loadCGImage(at: url) else {
            showToast("无法读取图片")
            return
        }
        importedCustomCG = cg
        sourceMode = .custom
        options.platform = .auto
        manualBoxes.removeAll()
        setSourceImage(cg)
        showToast("已载入截图，支持魔法划选")
    }

    public func handlePhotoPickerChange() {
        guard let item = selectedPhotoItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                importedCustomCG = cg
                sourceMode = .custom
                options.platform = .auto
                manualBoxes.removeAll()
                setSourceImage(cg)
                showToast("已导入相册截图")
            }
        }
    }

    public func regenerateNailongAliases() {
        guard !avatarVariants.isEmpty else { return }
        participants = AliasGenerator.makeParticipants(avatarVariants: avatarVariants)
        reprocess()
        showToast("已随机刷新奶龙情绪与编号")
    }

    public func reprocess() {
        guard let sourceCG else { return }
        if let result = ChatRedactionEngine.redact(
            source: sourceCG,
            participants: participants,
            options: options,
            manualBoxes: manualBoxes,
            precomputedOCR: ocrItems
        ) {
            redactedCG = result.image
            summary = result.summary
        }
    }

    /// Black Highlighter 核心交互：划选路径吸合到命中的 OCR 文本行上
    public func commitMagicStroke(normalizedRectsAlongPath strokeNormRects: [CGRect]) {
        guard let sourceCG else { return }
        let w = CGFloat(sourceCG.width)
        let h = CGFloat(sourceCG.height)

        var added = 0
        for item in ocrItems {
            let normItem = CGRect(
                x: item.rectTopLeft.minX / w,
                y: item.rectTopLeft.minY / h,
                width: item.rectTopLeft.width / w,
                height: item.rectTopLeft.height / h
            ).insetBy(dx: -0.004, dy: -0.003)

            let hit = strokeNormRects.contains { $0.intersects(normItem) }
            if hit {
                let alreadyExists = manualBoxes.contains { box in
                    abs(box.normalizedRect.midX - normItem.midX) < 0.02 &&
                    abs(box.normalizedRect.midY - normItem.midY) < 0.015
                }
                if !alreadyExists {
                    manualBoxes.append(ManualRedactionBox(
                        normalizedRect: normItem,
                        color: activeBarColor,
                        matchedOCRText: item.text
                    ))
                    added += 1
                }
            }
        }

        if added > 0 {
            reprocess()
            showToast("魔法吸合打码 \(added) 处文本")
        }
    }

    /// 单击 OCR 文本行快速切换打码/取消
    public func toggleOCRBox(atNormalizedPoint pt: CGPoint) {
        guard let sourceCG else { return }
        let w = CGFloat(sourceCG.width)
        let h = CGFloat(sourceCG.height)

        // 先检查是否点在已有手动框上（取消）
        if let idx = manualBoxes.lastIndex(where: { $0.normalizedRect.insetBy(dx: -0.01, dy: -0.01).contains(pt) }) {
            manualBoxes.remove(at: idx)
            reprocess()
            return
        }

        for item in ocrItems {
            let normItem = CGRect(
                x: item.rectTopLeft.minX / w,
                y: item.rectTopLeft.minY / h,
                width: item.rectTopLeft.width / w,
                height: item.rectTopLeft.height / h
            ).insetBy(dx: -0.005, dy: -0.004)
            if normItem.contains(pt) {
                manualBoxes.append(ManualRedactionBox(
                    normalizedRect: normItem,
                    color: activeBarColor,
                    matchedOCRText: item.text
                ))
                reprocess()
                return
            }
        }
    }

    public func commitFreeBox(normalizedRect: CGRect) {
        guard normalizedRect.width > 0.015 && normalizedRect.height > 0.01 else { return }
        manualBoxes.append(ManualRedactionBox(normalizedRect: normalizedRect, color: activeBarColor))
        reprocess()
    }

    public func undoLastBox() {
        guard !manualBoxes.isEmpty else { return }
        manualBoxes.removeLast()
        reprocess()
    }

    public func clearManualBoxes() {
        manualBoxes.removeAll()
        reprocess()
    }

    public func exportFlattenedData() -> Data? {
        guard let redactedCG else { return nil }
        return ChatRedactionEngine.exportFlattenedPNGData(from: redactedCG)
    }

    #if canImport(AppKit)
    public func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            importImage(from: url)
        }
    }

    public func saveExportPanel() {
        guard let data = exportFlattenedData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "奶龙隐私打码_无EXIF.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
            showToast("已导出无 EXIF 扁平图")
        }
    }
    #endif

    private func showToast(_ msg: String) {
        toastMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toastMessage == msg {
                toastMessage = nil
            }
        }
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let src = CGImageSourceCreateWithDataProvider(provider, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return cg
    }
}

/// iPhone 主界面（Black Highlighter 交互模型 + iOS 26 Liquid Glass 液态玻璃浮动控台）
public struct iPhoneAppView: View {
    @ObservedObject var vm: RedactStudioViewModel
    @Namespace private var glassNS

    public init(vm: RedactStudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        ZStack {
            // Black Highlighter 标志性深色沉浸画布
            Color(red: 0.06, green: 0.065, blue: 0.085)
                .ignoresSafeArea()

            // 核心截图画布 + 魔法划选 / 框选交互层
            canvasStage
                .padding(.top, 58)
                .padding(.bottom, 92)

            // 顶部浮动 Liquid Glass 导航胶囊
            VStack {
                topGlassBar
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                if let toast = vm.toastMessage {
                    Text(toast)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .adaptiveGlass(tint: .indigo, interactive: false, shape: .capsule)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }

                Spacer()
            }

            // 底部浮动 Liquid Glass 抽屉 + 控台工具坞
            VStack(spacing: 10) {
                Spacer()

                if vm.activeDrawer != .none {
                    expandedGlassDrawer
                        .padding(.horizontal, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                bottomGlassDock
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: vm.activeDrawer)
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage)
        .preferredColorScheme(.dark)
        .onChange(of: vm.selectedPhotoItem) {
            vm.handlePhotoPickerChange()
        }
    }

    // MARK: - 画布与 Black Highlighter 手势层

    private var canvasStage: some View {
        GeometryReader { geo in
            let displayCG = vm.isPeekingOriginal ? vm.sourceCG : vm.redactedCG

            ZStack {
                if let displayCG {
                    let imgAspect = CGFloat(displayCG.width) / max(1, CGFloat(displayCG.height))
                    let fitSize = aspectFitSize(aspect: imgAspect, in: geo.size)

                    ZStack {
                        Image(platformImage: PlatformImage.from(cgImage: displayCG))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)

                        // 魔法划选模式下展示极淡的文本块提示底线，暗示可一划即吸合
                        if vm.toolMode == .magicHighlighter && !vm.isPeekingOriginal {
                            ocrHintOverlay(imageCG: displayCG, fitSize: fitSize)
                        }

                        // 实时荧光笔划动轨迹 / 自由框选矩形预览
                        liveGestureOverlay(fitSize: fitSize)
                    }
                    .frame(width: fitSize.width, height: fitSize.height)
                    .contentShape(Rectangle())
                    .gesture(canvasGesture(fitSize: fitSize))
                    .onTapGesture { location in
                        guard vm.toolMode == .magicHighlighter else { return }
                        let normPt = CGPoint(
                            x: min(1, max(0, location.x / fitSize.width)),
                            y: min(1, max(0, location.y / fitSize.height))
                        )
                        vm.toggleOCRBox(atNormalizedPoint: normPt)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 38))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("导入微信 / QQ 聊天截图开始打码")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 12)
    }

    private func ocrHintOverlay(imageCG: CGImage, fitSize: CGSize) -> some View {
        let imgW = CGFloat(imageCG.width)
        let imgH = CGFloat(imageCG.height)
        return ZStack(alignment: .topLeading) {
            ForEach(vm.ocrItems) { item in
                let rx = item.rectTopLeft.minX / imgW * fitSize.width
                let ry = item.rectTopLeft.minY / imgH * fitSize.height
                let rw = item.rectTopLeft.width / imgW * fitSize.width
                let rh = item.rectTopLeft.height / imgH * fitSize.height
                Rectangle()
                    .fill(Color.clear)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: 1)
                    }
                    .frame(width: rw, height: rh)
                    .offset(x: rx, y: ry)
            }
        }
        .frame(width: fitSize.width, height: fitSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func liveGestureOverlay(fitSize: CGSize) -> some View {
        ZStack {
            if vm.toolMode == .magicHighlighter && vm.dragPoints.count > 1 {
                Path { path in
                    path.move(to: vm.dragPoints[0])
                    for pt in vm.dragPoints.dropFirst() {
                        path.addLine(to: pt)
                    }
                }
                .stroke(
                    vm.activeBarColor.swiftUIColor.opacity(0.65),
                    style: StrokeStyle(lineWidth: 22, lineCap: .round, lineJoin: .round)
                )
            }

            if vm.toolMode == .freeBox, let origin = vm.freeDragOrigin, let current = vm.freeDragCurrent {
                let rect = CGRect(
                    x: min(origin.x, current.x),
                    y: min(origin.y, current.y),
                    width: abs(current.x - origin.x),
                    height: abs(current.y - origin.y)
                )
                RoundedRectangle(cornerRadius: 4)
                    .fill(vm.activeBarColor.swiftUIColor.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.8), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: fitSize.width, height: fitSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func canvasGesture(fitSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let clamped = CGPoint(
                    x: min(fitSize.width, max(0, value.location.x)),
                    y: min(fitSize.height, max(0, value.location.y))
                )
                if vm.toolMode == .magicHighlighter {
                    if vm.dragPoints.isEmpty {
                        let start = CGPoint(
                            x: min(fitSize.width, max(0, value.startLocation.x)),
                            y: min(fitSize.height, max(0, value.startLocation.y))
                        )
                        vm.dragPoints.append(start)
                    }
                    vm.dragPoints.append(clamped)
                } else {
                    if vm.freeDragOrigin == nil {
                        vm.freeDragOrigin = CGPoint(
                            x: min(fitSize.width, max(0, value.startLocation.x)),
                            y: min(fitSize.height, max(0, value.startLocation.y))
                        )
                    }
                    vm.freeDragCurrent = clamped
                }
            }
            .onEnded { _ in
                if vm.toolMode == .magicHighlighter {
                    let hitNormRects = vm.dragPoints.map { pt in
                        CGRect(
                            x: (pt.x - 10) / fitSize.width,
                            y: (pt.y - 10) / fitSize.height,
                            width: 20 / fitSize.width,
                            height: 20 / fitSize.height
                        )
                    }
                    vm.commitMagicStroke(normalizedRectsAlongPath: hitNormRects)
                    vm.dragPoints.removeAll()
                } else if let origin = vm.freeDragOrigin, let current = vm.freeDragCurrent {
                    let normRect = CGRect(
                        x: min(origin.x, current.x) / fitSize.width,
                        y: min(origin.y, current.y) / fitSize.height,
                        width: abs(current.x - origin.x) / fitSize.width,
                        height: abs(current.y - origin.y) / fitSize.height
                    )
                    vm.commitFreeBox(normalizedRect: normRect)
                    vm.freeDragOrigin = nil
                    vm.freeDragCurrent = nil
                }
            }
    }

    // MARK: - 顶部 Liquid Glass 悬浮栏

    private var topGlassBar: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 8) {
                #if os(iOS)
                PhotosPicker(selection: $vm.selectedPhotoItem, matching: .screenshots) {
                    Label("相册", systemImage: "photo.on.rectangle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .adaptiveGlass(interactive: true, shape: .capsule)
                #else
                Button {
                    vm.openFilePanel()
                } label: {
                    Label("导入", systemImage: "photo.on.rectangle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(interactive: true, shape: .capsule)
                #endif

                Spacer()

                // 按住预览原图按钮（Black Highlighter 经典长按对比交互）
                HStack(spacing: 4) {
                    Image(systemName: vm.isPeekingOriginal ? "eye.fill" : "eye")
                        .font(.caption.weight(.semibold))
                    Text(vm.isPeekingOriginal ? "原图" : "对比")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .adaptiveGlass(tint: vm.isPeekingOriginal ? .orange : nil, interactive: true, shape: .capsule)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in vm.isPeekingOriginal = true }
                        .onEnded { _ in vm.isPeekingOriginal = false }
                )

                // 撤销手动涂抹
                Button {
                    vm.undoLastBox()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(vm.manualBoxes.isEmpty)
                .opacity(vm.manualBoxes.isEmpty ? 0.45 : 1.0)
                .adaptiveGlass(interactive: true, shape: .circle)

                // 分享 / 导出无 EXIF 图
                #if os(iOS)
                if let pngData = vm.exportFlattenedData(), let img = vm.redactedCG {
                    ShareLink(
                        item: FlattenedPNGTransfer(data: pngData),
                        preview: SharePreview("奶龙隐私打码图", image: Image(platformImage: PlatformImage.from(cgImage: img)))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.weight(.bold))
                            .frame(width: 36, height: 34)
                    }
                    .adaptiveGlass(tint: .blue, interactive: true, shape: .circle)
                }
                #else
                Button {
                    vm.saveExportPanel()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption.weight(.bold))
                        .frame(width: 36, height: 34)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(tint: .blue, interactive: true, shape: .circle)
                #endif
            }
        }
    }

    // MARK: - 底部 Liquid Glass 悬浮坞 & 可形变抽屉

    private var bottomGlassDock: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 8) {
                // 一键奶龙自动打码开关
                Button {
                    vm.options.autoNailongChat.toggle()
                    vm.reprocess()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.bold))
                        Text("奶龙")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(
                    tint: vm.options.autoNailongChat ? Color(red: 86/255, green: 89/255, blue: 201/255) : nil,
                    interactive: true,
                    shape: .capsule
                )
                .adaptiveGlassID("nailongToggle", in: glassNS)

                // Black Highlighter 魔法划选
                Button {
                    vm.toolMode = .magicHighlighter
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "highlighter")
                            .font(.caption.weight(.semibold))
                        Text("划选")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(
                    tint: vm.toolMode == .magicHighlighter ? .teal : nil,
                    interactive: true,
                    shape: .capsule
                )
                .adaptiveGlassID("magicTool", in: glassNS)

                // 自由框选
                Button {
                    vm.toolMode = .freeBox
                } label: {
                    Image(systemName: "rectangle.dashed")
                        .font(.caption.weight(.semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(
                    tint: vm.toolMode == .freeBox ? .teal : nil,
                    interactive: true,
                    shape: .circle
                )
                .adaptiveGlassID("boxTool", in: glassNS)

                // 颜色抽屉按钮（显示当前实心涂抹颜色点）
                Button {
                    vm.activeDrawer = (vm.activeDrawer == .colors) ? .none : .colors
                } label: {
                    Circle()
                        .fill(vm.activeBarColor.swiftUIColor)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(tint: vm.activeDrawer == .colors ? .white.opacity(0.25) : nil, interactive: true, shape: .circle)
                .adaptiveGlassID("colorDrawer", in: glassNS)

                // 10人奶龙 & 隐私面板开关
                Button {
                    vm.activeDrawer = (vm.activeDrawer == .nailongSettings) ? .none : .nailongSettings
                } label: {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.caption.weight(.semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(tint: vm.activeDrawer == .nailongSettings ? .indigo : nil, interactive: true, shape: .circle)
                .adaptiveGlassID("settingsDrawer", in: glassNS)
            }
        }
    }

    @ViewBuilder
    private var expandedGlassDrawer: some View {
        switch vm.activeDrawer {
        case .none:
            EmptyView()
        case .colors:
            AdaptiveGlassContainer(spacing: 10) {
                HStack(spacing: 12) {
                    ForEach(RedactionColorStyle.allCases) { style in
                        Button {
                            vm.activeBarColor = style
                            vm.options.privacyBarColor = style
                            vm.reprocess()
                        } label: {
                            VStack(spacing: 3) {
                                Circle()
                                    .fill(style.swiftUIColor)
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle().stroke(
                                            vm.activeBarColor == style ? Color.white : Color.white.opacity(0.25),
                                            lineWidth: vm.activeBarColor == style ? 2.5 : 1
                                        )
                                    )
                                Text(style.rawValue)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .adaptiveGlass(interactive: true, shape: .roundedRect(22))
                .adaptiveGlassID("colorDrawer", in: glassNS)
            }

        case .nailongSettings:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("10 人奶龙头像与脱敏")
                        .font(.caption.bold())
                    Spacer()
                    Button("重抽情绪") {
                        vm.regenerateNailongAliases()
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .adaptiveGlass(tint: .blue, interactive: true, shape: .capsule)
                }

                // 10 色奶龙头像横向预览条
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.participants.prefix(vm.options.maxParticipants)) { p in
                            HStack(spacing: 5) {
                                Image(platformImage: PlatformImage.from(cgImage: p.avatarCGImage))
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 26, height: 26)
                                    .clipShape(RoundedRectangle(cornerRadius: vm.summary?.detectedPlatform == .qq ? 13 : 5))
                                Text(p.displayName)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(p.color.swiftUIColor.opacity(0.28))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                HStack(spacing: 10) {
                    Text("人数 \(vm.options.maxParticipants)")
                        .font(.caption2)
                        .monospacedDigit()
                    Slider(
                        value: Binding(
                            get: { Double(vm.options.maxParticipants) },
                            set: {
                                vm.options.maxParticipants = Int($0.rounded())
                                if vm.sourceMode != .custom {
                                    vm.loadSample(for: vm.sourceMode == .qq ? .qq : .wechat)
                                } else {
                                    vm.reprocess()
                                }
                            }
                        ),
                        in: 1...10,
                        step: 1
                    )
                }

                HStack(spacing: 12) {
                    Toggle("手机", isOn: $vm.options.redactPhones)
                        .onChange(of: vm.options.redactPhones) { vm.reprocess() }
                    Toggle("证件", isOn: $vm.options.redactIDsAndCards)
                        .onChange(of: vm.options.redactIDsAndCards) { vm.reprocess() }
                    Toggle("@提及", isOn: $vm.options.redactMentions)
                        .onChange(of: vm.options.redactMentions) { vm.reprocess() }
                }
                .font(.caption2)
                .toggleStyle(.switch)
                .controlSize(.mini)

                if let s = vm.summary {
                    Text("已识别 \(s.detectedPlatform.rawValue) · \(s.avatarCount) 头像 · \(s.nameReplacementCount) 名字 · \(s.privacyHitCount) 隐私 · \(s.manualBoxCount) 划选")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(14)
            .adaptiveGlass(interactive: true, shape: .roundedRect(24))
            .adaptiveGlassID("settingsDrawer", in: glassNS)
        }
    }

    private func aspectFitSize(aspect: CGFloat, in container: CGSize) -> CGSize {
        guard container.width > 0 && container.height > 0 else { return .zero }
        let containerAspect = container.width / container.height
        if aspect > containerAspect {
            let w = container.width
            return CGSize(width: w, height: w / aspect)
        } else {
            let h = container.height
            return CGSize(width: h * aspect, height: h)
        }
    }
}
