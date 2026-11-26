#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

echo "正在编译 iPhone 应用预览壳 (含 iOS 26 Liquid Glass + Black Highlighter 交互 + AppIntents)..."
swiftc -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework PhotosUI \
  -framework AppIntents \
  -framework Vision \
  -framework CoreGraphics \
  -framework CoreText \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  Models.swift AvatarRecolorEngine.swift SampleChatGenerator.swift ChatRedactionEngine.swift LiquidGlassHelpers.swift ShortcutsIntent.swift iPhoneAppView.swift PreviewApp.swift \
  -o ChatRedactPreviewBin

echo "启动 iPhone 真机尺寸实时预览..."
./ChatRedactPreviewBin
