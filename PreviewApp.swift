import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

/// Mac 无 Xcode 下的 iPhone 真机尺寸实时交互仿真框（393 × 852，内置完整液态玻璃 UI 与鼠标模拟手指划选）
struct MacPhoneSimulatorShell: View {
    @StateObject private var vm = RedactStudioViewModel()

    var body: some View {
        VStack(spacing: 12) {
            // 外部控制台：仅用于快速切换微信/QQ 测试源或拖入真实截图
            HStack(spacing: 12) {
                Picker("测试场景", selection: Binding(
                    get: { vm.sourceMode },
                    set: { vm.switchSource($0) }
                )) {
                    ForEach(RedactStudioViewModel.MockSourceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Button("导入真实截图…") {
                    vm.openFilePanel()
                }

                Button("随机刷新奶龙") {
                    vm.regenerateNailongAliases()
                }

                Button("清空手动划选") {
                    vm.clearManualBoxes()
                }
                .disabled(vm.manualBoxes.isEmpty)

                Spacer()

                Text("支持鼠标在手机屏幕内划选文字吸附打码（参考 Black Highlighter + iOS 26 Liquid Glass）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            // iPhone 手机真机框（393 × 852 pt 逻辑分辨率）
            ZStack(alignment: .top) {
                iPhoneAppView(vm: vm)
                    .frame(width: 393, height: 852)
                    .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))

                // 灵动岛指示条
                Capsule()
                    .fill(Color.black)
                    .frame(width: 112, height: 30)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
            .frame(width: 393, height: 852)
            .overlay(
                RoundedRectangle(cornerRadius: 48, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 3)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
            .padding(.bottom, 14)
        }
        .frame(minWidth: 820, minHeight: 940)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in
                        vm.importImage(from: url)
                    }
                }
            }
            return true
        }
    }
}

@main
enum PreviewRunner {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--export-check") {
            runHeadlessVerification()
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 960),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "奶龙打码 · iPhone 应用交互预览 (Liquid Glass + Black Highlighter)"
        window.center()
        window.contentView = NSHostingView(rootView: MacPhoneSimulatorShell())
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        app.run()
    }

    @MainActor
    static func runHeadlessVerification() {
        let vm = RedactStudioViewModel()
        guard let base = vm.baseAvatarCG else {
            fputs("ERROR: avatar_base.jpg not found\n", stderr)
            exit(1)
        }
        let variants = AvatarRecolorEngine.generateTenVariants(from: base)
        print("Generated \(variants.count) avatar variants.")

        let participants = AliasGenerator.makeParticipants(avatarVariants: variants, seed: 12138)
        let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("verify_out")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for (tag, platform) in [("wechat", ChatPlatform.wechat), ("qq", ChatPlatform.qq)] {
            if let sample = SampleChatGenerator.generate(platform: platform, participantCount: 10) {
                var opts = RedactionOptions()
                opts.platform = platform
                // 附带一条模拟的 Black Highlighter 手动划选框测试
                let manual = [ManualRedactionBox(normalizedRect: CGRect(x: 0.22, y: 0.56, width: 0.34, height: 0.024), color: .inkBlack)]
                if let res = ChatRedactionEngine.redact(source: sample, participants: participants, options: opts, manualBoxes: manual),
                   let pngData = ChatRedactionEngine.exportFlattenedPNGData(from: res.image) {
                    try? pngData.write(to: outDir.appendingPathComponent("\(tag)_after.png"))
                    print("[\(tag)] avatars=\(res.summary.avatarCount) names=\(res.summary.nameReplacementCount) privacy=\(res.summary.privacyHitCount) manual=\(res.summary.manualBoxCount) pngBytes=\(pngData.count)")
                }
            }
        }
    }
}
#endif
