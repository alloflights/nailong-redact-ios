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
    @Published public var toolMode: EditorToolMode = .swipeMosaic
    @Published public var showSettingsDrawer: Bool = false

    @Published public var options = RedactionOptions()
    @Published public var baseAvatarCG: CGImage?
    @Published public var participants: [ParticipantIdentity] = []

    @Published public var sourceCG: CGImage?
    @Published public var ocrItems: [OCRItem] = []
    @Published public var manualMosaics: [ManualMosaicBox] = []
    @Published private var undoHistory: [[ManualMosaicBox]] = []
    @Published private var redoHistory: [[ManualMosaicBox]] = []

    @Published public var redactedCG: CGImage?
    @Published public var summary: RedactionSummary?

    @Published public var isPeekingOriginal = false
    @Published public var selectedPhotoItem: PhotosPickerItem?

    @Published public var dragPoints: [CGPoint] = []
    @Published public var freeDragOrigin: CGPoint?
    @Published public var freeDragCurrent: CGPoint?

    private var avatarVariants: [CGImage] = []

    public init() {
        loadBaseAvatar()
        if !avatarVariants.isEmpty {
            participants = AliasGenerator.makeParticipants(avatarVariants: avatarVariants)
        }
        // 启动时不放任何预览图，等待用户导入真实截图
    }

    public var canUndo: Bool { !undoHistory.isEmpty }
    public var canRedo: Bool { !redoHistory.isEmpty }

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

    public func setSourceImage(_ cg: CGImage) {
        sourceCG = cg
        manualMosaics = []
        undoHistory = []
        redoHistory = []
        ocrItems = ChatRedactionEngine.performOCR(on: cg)
        reprocess()
    }

    public func importImage(from url: URL) {
        guard let cg = Self.loadCGImage(at: url) else { return }
        setSourceImage(cg)
    }

    public func handlePhotoPickerChange() {
        guard let item = selectedPhotoItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                setSourceImage(cg)
            }
        }
    }

    public func regenerateNailongAliases() {
        guard !avatarVariants.isEmpty else { return }
        let regenerated = AliasGenerator.makeParticipants(avatarVariants: avatarVariants)
        // 按当前人物优先级顺序刷新各奶龙对应的新随机情绪与编号
        let byColorID = Dictionary(uniqueKeysWithValues: regenerated.map { ($0.color.id, $0) })
        participants = participants.compactMap { existing in
            byColorID[existing.color.id]
        }
        reprocess()
    }

    public func moveParticipantUp(at index: Int) {
        guard index > 0 && index < participants.count else { return }
        participants.swapAt(index, index - 1)
        reprocess()
    }

    public func moveParticipantDown(at index: Int) {
        guard index >= 0 && index + 1 < participants.count else { return }
        participants.swapAt(index, index + 1)
        reprocess()
    }

    public func reprocess() {
        guard let sourceCG else { return }
        if let result = ChatRedactionEngine.redact(
            source: sourceCG,
            participants: participants,
            options: options,
            manualMosaics: manualMosaics,
            precomputedOCR: ocrItems
        ) {
            redactedCG = result.image
            summary = result.summary
        }
    }

    private func pushMosaicSnapshot(_ newBoxes: [ManualMosaicBox]) {
        undoHistory.append(manualMosaics)
        redoHistory.removeAll()
        manualMosaics = newBoxes
        reprocess()
    }

    /// 指哪里打哪里：命中文字时按逐字包围盒局部对齐吸合，非文字区域按划选轨迹打马赛克，绝不整行误伤、绝不弹窗
    public func commitSwipeMosaic(normalizedPathPoints: [CGPoint]) {
        guard let sourceCG, !normalizedPathPoints.isEmpty else { return }
        let w = CGFloat(sourceCG.width)
        let h = CGFloat(sourceCG.height)

        let hitRadiusX: CGFloat = 0.015
        let hitRadiusY: CGFloat = 0.012
        var addedBoxes: [ManualMosaicBox] = []

        for item in ocrItems {
            guard !item.charBoxes.isEmpty else { continue }
            var hitIndices: [Int] = []
            for (ci, charBox) in item.charBoxes.enumerated() {
                let normChar = CGRect(
                    x: charBox.rectTopLeft.minX / w,
                    y: charBox.rectTopLeft.minY / h,
                    width: charBox.rectTopLeft.width / w,
                    height: charBox.rectTopLeft.height / h
                ).insetBy(dx: -hitRadiusX, dy: -hitRadiusY)

                if normalizedPathPoints.contains(where: { normChar.contains($0) }) {
                    hitIndices.append(ci)
                }
            }

            guard !hitIndices.isEmpty else { continue }

            // 合并相邻或仅隔 1 个字符的连续命中片段，保留局部精准度同时不出现细碎裂缝
            var segments: [(Int, Int)] = []
            for idx in hitIndices {
                if let last = segments.last, idx - last.1 <= 2 {
                    segments[segments.count - 1].1 = idx
                } else {
                    segments.append((idx, idx))
                }
            }

            for (s, e) in segments {
                var unionRect = item.charBoxes[s].rectTopLeft
                for k in (s + 1)...e {
                    unionRect = unionRect.union(item.charBoxes[k].rectTopLeft)
                }
                let normRect = CGRect(
                    x: max(0, (unionRect.minX - 2) / w),
                    y: max(0, (unionRect.minY - 2) / h),
                    width: min(1, (unionRect.width + 4) / w),
                    height: min(1, (unionRect.height + 4) / h)
                )
                addedBoxes.append(ManualMosaicBox(normalizedRect: normRect))
            }
        }

        // 若划过区域未命中任何文字（如表情包/图片/空白处），直接按手指轨迹分段打马赛克
        if addedBoxes.isEmpty {
            let brushW: CGFloat = 0.055
            let brushH: CGFloat = 0.032
            for pt in normalizedPathPoints {
                let stamp = CGRect(
                    x: max(0, pt.x - brushW / 2),
                    y: max(0, pt.y - brushH / 2),
                    width: min(brushW, 1 - max(0, pt.x - brushW / 2)),
                    height: min(brushH, 1 - max(0, pt.y - brushH / 2))
                )
                if let last = addedBoxes.last, last.normalizedRect.intersects(stamp) {
                    let merged = last.normalizedRect.union(stamp)
                    addedBoxes[addedBoxes.count - 1] = ManualMosaicBox(normalizedRect: merged)
                } else {
                    addedBoxes.append(ManualMosaicBox(normalizedRect: stamp))
                }
            }
        }

        if !addedBoxes.isEmpty {
            pushMosaicSnapshot(manualMosaics + addedBoxes)
        }
    }

    /// 点哪里打哪里（或点击已有马赛克撤销）
    public func handleCanvasTap(atNormalizedPoint pt: CGPoint) {
        guard let sourceCG else { return }
        let w = CGFloat(sourceCG.width)
        let h = CGFloat(sourceCG.height)

        if let idx = manualMosaics.lastIndex(where: { $0.normalizedRect.insetBy(dx: -0.008, dy: -0.008).contains(pt) }) {
            var next = manualMosaics
            next.remove(at: idx)
            pushMosaicSnapshot(next)
            return
        }

        // 命中某个字符时，局部打码该词组（前后最多延伸 2 个相邻字），不打整行
        for item in ocrItems where !item.charBoxes.isEmpty {
            for (ci, charBox) in item.charBoxes.enumerated() {
                let normChar = CGRect(
                    x: charBox.rectTopLeft.minX / w,
                    y: charBox.rectTopLeft.minY / h,
                    width: charBox.rectTopLeft.width / w,
                    height: charBox.rectTopLeft.height / h
                ).insetBy(dx: -0.008, dy: -0.008)
                if normChar.contains(pt) {
                    let lo = max(0, ci - 1)
                    let hi = min(item.charBoxes.count - 1, ci + 1)
                    var unionRect = item.charBoxes[lo].rectTopLeft
                    for k in lo...hi {
                        unionRect = unionRect.union(item.charBoxes[k].rectTopLeft)
                    }
                    let normRect = CGRect(
                        x: max(0, (unionRect.minX - 2) / w),
                        y: max(0, (unionRect.minY - 2) / h),
                        width: min(1, (unionRect.width + 4) / w),
                        height: min(1, (unionRect.height + 4) / h)
                    )
                    pushMosaicSnapshot(manualMosaics + [ManualMosaicBox(normalizedRect: normRect)])
                    return
                }
            }
        }

        // 非文字区域：在点击处生成一小块马赛克
        let stamp = CGRect(x: max(0, pt.x - 0.03), y: max(0, pt.y - 0.018), width: 0.06, height: 0.036)
        pushMosaicSnapshot(manualMosaics + [ManualMosaicBox(normalizedRect: stamp)])
    }

    public func commitFreeBoxMosaic(normalizedRect: CGRect) {
        guard normalizedRect.width > 0.012 && normalizedRect.height > 0.008 else { return }
        pushMosaicSnapshot(manualMosaics + [ManualMosaicBox(normalizedRect: normalizedRect)])
    }

    public func undo() {
        guard let prev = undoHistory.popLast() else { return }
        redoHistory.append(manualMosaics)
        manualMosaics = prev
        reprocess()
    }

    public func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(manualMosaics)
        manualMosaics = next
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
        }
    }
    #endif

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let src = CGImageSourceCreateWithDataProvider(provider, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return cg
    }
}

/// iPhone 主界面（统一蓝色强调色 + iOS 26 液态玻璃浮动控台 + 指哪打哪马赛克）
public struct iPhoneAppView: View {
    @ObservedObject var vm: RedactStudioViewModel
    @Namespace private var glassNS

    public init(vm: RedactStudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.065, blue: 0.085)
                .ignoresSafeArea()

            canvasStage
                .padding(.top, 58)
                .padding(.bottom, 92)

            VStack {
                topGlassBar
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                Spacer()
            }

            VStack(spacing: 10) {
                Spacer()

                if vm.showSettingsDrawer {
                    expandedSettingsDrawer
                        .padding(.horizontal, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                bottomGlassDock
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .tint(.blue)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: vm.showSettingsDrawer)
        .preferredColorScheme(.dark)
        .onChange(of: vm.selectedPhotoItem) {
            vm.handlePhotoPickerChange()
        }
    }

    // MARK: - 画布与指哪打哪马赛克交互层

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

                        liveGestureOverlay(fitSize: fitSize)
                    }
                    .frame(width: fitSize.width, height: fitSize.height)
                    .contentShape(Rectangle())
                    .gesture(canvasGesture(fitSize: fitSize))
                    .onTapGesture { location in
                        let normPt = CGPoint(
                            x: min(1, max(0, location.x / fitSize.width)),
                            y: min(1, max(0, location.y / fitSize.height))
                        )
                        vm.handleCanvasTap(atNormalizedPoint: normPt)
                    }
                } else {
                    emptyImportView
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 12)
    }

    private var emptyImportView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.75))

            Text("导入微信或 QQ 聊天截图")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.88))

            #if os(iOS)
            PhotosPicker(selection: $vm.selectedPhotoItem, matching: .images) {
                Label("从相册选择截图", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
            }
            .adaptiveGlass(tint: .blue, interactive: true, shape: .capsule)
            #else
            Button {
                vm.openFilePanel()
            } label: {
                Label("导入截图", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .adaptiveGlass(tint: .blue, interactive: true, shape: .capsule)
            #endif
        }
    }

    private func liveGestureOverlay(fitSize: CGSize) -> some View {
        ZStack {
            if vm.toolMode == .swipeMosaic && vm.dragPoints.count > 1 {
                Path { path in
                    path.move(to: vm.dragPoints[0])
                    for pt in vm.dragPoints.dropFirst() {
                        path.addLine(to: pt)
                    }
                }
                .stroke(
                    Color.blue.opacity(0.55),
                    style: StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round)
                )
            }

            if vm.toolMode == .freeBoxMosaic, let origin = vm.freeDragOrigin, let current = vm.freeDragCurrent {
                let rect = CGRect(
                    x: min(origin.x, current.x),
                    y: min(origin.y, current.y),
                    width: abs(current.x - origin.x),
                    height: abs(current.y - origin.y)
                )
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.blue.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.85), lineWidth: 1))
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
                if vm.toolMode == .swipeMosaic {
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
                if vm.toolMode == .swipeMosaic {
                    let normPoints = vm.dragPoints.map { pt in
                        CGPoint(x: pt.x / fitSize.width, y: pt.y / fitSize.height)
                    }
                    vm.commitSwipeMosaic(normalizedPathPoints: normPoints)
                    vm.dragPoints.removeAll()
                } else if let origin = vm.freeDragOrigin, let current = vm.freeDragCurrent {
                    let normRect = CGRect(
                        x: min(origin.x, current.x) / fitSize.width,
                        y: min(origin.y, current.y) / fitSize.height,
                        width: abs(current.x - origin.x) / fitSize.width,
                        height: abs(current.y - origin.y) / fitSize.height
                    )
                    vm.commitFreeBoxMosaic(normalizedRect: normRect)
                    vm.freeDragOrigin = nil
                    vm.freeDragCurrent = nil
                }
            }
    }

    // MARK: - 顶部 Liquid Glass 导航栏

    private var topGlassBar: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 8) {
                #if os(iOS)
                PhotosPicker(selection: $vm.selectedPhotoItem, matching: .images) {
                    Label("相册", systemImage: "photo.on.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(interactive: true, shape: .capsule)
                #endif

                Spacer()

                // 对比按钮：仅保留眼睛图标，无文字
                Image(systemName: vm.isPeekingOriginal ? "eye.fill" : "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 34)
                    .adaptiveGlass(tint: vm.isPeekingOriginal ? .blue : nil, interactive: true, shape: .circle)
                    .opacity(vm.sourceCG == nil ? 0.45 : 1.0)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in if vm.sourceCG != nil { vm.isPeekingOriginal = true } }
                            .onEnded { _ in vm.isPeekingOriginal = false }
                    )

                // 回退（撤销）按钮
                Button {
                    vm.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canUndo)
                .opacity(vm.canUndo ? 1.0 : 0.4)
                .adaptiveGlass(interactive: true, shape: .circle)

                // 前进（重做）按钮，紧挨回退按钮右侧
                Button {
                    vm.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canRedo)
                .opacity(vm.canRedo ? 1.0 : 0.4)
                .adaptiveGlass(interactive: true, shape: .circle)

                // 导出按钮（白色图标 + 蓝色玻璃）
                #if os(iOS)
                if let pngData = vm.exportFlattenedData(), let img = vm.redactedCG {
                    ShareLink(
                        item: FlattenedPNGTransfer(data: pngData),
                        preview: SharePreview("奶龙隐私打码图", image: Image(platformImage: PlatformImage.from(cgImage: img)))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 34)
                    }
                    .adaptiveGlass(tint: .blue, interactive: true, shape: .circle)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 36, height: 34)
                        .adaptiveGlass(tint: .blue.opacity(0.45), interactive: false, shape: .circle)
                }
                #else
                Button {
                    vm.saveExportPanel()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(vm.redactedCG == nil)
                .opacity(vm.redactedCG == nil ? 0.45 : 1.0)
                .adaptiveGlass(tint: .blue, interactive: true, shape: .circle)
                #endif
            }
        }
    }

    // MARK: - 底部 Liquid Glass 控台与抽屉

    private var bottomGlassDock: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                // 左下角按钮：改名为“奶龙化”
                Button {
                    vm.options.autoNailongChat.toggle()
                    vm.reprocess()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.bold))
                        Text("奶龙化")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(
                    tint: vm.options.autoNailongChat ? .blue : nil,
                    interactive: true,
                    shape: .capsule
                )
                .adaptiveGlassID("nailongToggle", in: glassNS)

                // 划选马赛克（指哪打哪）
                Button {
                    vm.toolMode = .swipeMosaic
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "scribble.variable")
                            .font(.caption.weight(.semibold))
                        Text("划选")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(
                    tint: vm.toolMode == .swipeMosaic ? .blue : nil,
                    interactive: true,
                    shape: .capsule
                )
                .adaptiveGlassID("swipeTool", in: glassNS)

                // 框选马赛克
                Button {
                    vm.toolMode = .freeBoxMosaic
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.dashed")
                            .font(.caption.weight(.semibold))
                        Text("框选")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(
                    tint: vm.toolMode == .freeBoxMosaic ? .blue : nil,
                    interactive: true,
                    shape: .capsule
                )
                .adaptiveGlassID("boxTool", in: glassNS)

                // 多人与隐私设置抽屉开关
                Button {
                    vm.showSettingsDrawer.toggle()
                } label: {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 38)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(tint: vm.showSettingsDrawer ? .blue : nil, interactive: true, shape: .circle)
                .adaptiveGlassID("settingsDrawer", in: glassNS)
            }
        }
    }

    // MARK: - 多人优先级与隐藏信息分段菜单

    private var expandedSettingsDrawer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 第一段：人物优先级（支持调序与自定义改名，无人数上限滑块）
                HStack {
                    Text("人物优先级")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        vm.regenerateNailongAliases()
                    } label: {
                        Text("随机重抽")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .adaptiveGlass(tint: .blue, interactive: true, shape: .capsule)
                }

                VStack(spacing: 8) {
                    ForEach(Array(vm.participants.enumerated()), id: \.element.id) { index, p in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(width: 18)

                            Image(platformImage: PlatformImage.from(cgImage: p.avatarCGImage))
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            TextField(
                                "奶龙昵称",
                                text: Binding(
                                    get: { vm.participants[index].displayName },
                                    set: { newVal in
                                        vm.participants[index].displayName = newVal
                                        vm.reprocess()
                                    }
                                )
                            )
                            .textFieldStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                            Button {
                                vm.moveParticipantUp(at: index)
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            .opacity(index == 0 ? 0.3 : 1.0)

                            Button {
                                vm.moveParticipantDown(at: index)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .disabled(index == vm.participants.count - 1)
                            .opacity(index == vm.participants.count - 1 ? 0.3 : 1.0)
                        }
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.18))

                // 第二段：需要隐藏的信息
                Text("需要隐藏的信息")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Toggle("手机号", isOn: $vm.options.redactPhones)
                        .onChange(of: vm.options.redactPhones) { vm.reprocess() }
                    Toggle("身份证 / 银行卡", isOn: $vm.options.redactIDsAndCards)
                        .onChange(of: vm.options.redactIDsAndCards) { vm.reprocess() }
                    Toggle("微信号 / 邮箱", isOn: $vm.options.redactAccountsAndEmails)
                        .onChange(of: vm.options.redactAccountsAndEmails) { vm.reprocess() }
                    Toggle("@提及替换", isOn: $vm.options.redactMentions)
                        .onChange(of: vm.options.redactMentions) { vm.reprocess() }
                    Toggle("顶部群名 / 备注", isOn: $vm.options.maskTopTitle)
                        .onChange(of: vm.options.maskTopTitle) { vm.reprocess() }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .tint(.blue)

                // 识别统计数据（字号调大，直接显示“已识别”）
                if let s = vm.summary {
                    Divider()
                        .background(Color.white.opacity(0.18))
                    Text("已识别：\(s.detectedPlatform.rawValue) · 头像 \(s.avatarCount) · 名字 \(s.nameReplacementCount) · 隐私 \(s.privacyHitCount) · 马赛克 \(s.mosaicCount)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 360)
        .adaptiveGlass(interactive: true, shape: .roundedRect(24))
        .adaptiveGlassID("settingsDrawer", in: glassNS)
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
