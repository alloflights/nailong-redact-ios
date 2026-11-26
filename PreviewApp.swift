import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

/// Mac 本地调试壳（仅作编译校验与无头测试入口）
struct MacPhoneSimulatorShell: View {
    @StateObject private var vm = RedactStudioViewModel()

    var body: some View {
        iPhoneAppView(vm: vm)
            .frame(width: 393, height: 852)
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
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 880),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NailongRedact"
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
                let manual = [ManualMosaicBox(normalizedRect: CGRect(x: 0.22, y: 0.56, width: 0.22, height: 0.024))]
                if let res = ChatRedactionEngine.redact(source: sample, participants: participants, options: opts, manualMosaics: manual),
                   let pngData = ChatRedactionEngine.exportFlattenedPNGData(from: res.image) {
                    try? pngData.write(to: outDir.appendingPathComponent("\(tag)_after.png"))
                    print("[\(tag)] avatars=\(res.summary.avatarCount) names=\(res.summary.nameReplacementCount) privacy=\(res.summary.privacyHitCount) mosaic=\(res.summary.mosaicCount) pngBytes=\(pngData.count)")
                }
            }
        }
    }
}
#endif
