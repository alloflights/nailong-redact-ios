import Foundation
import CoreGraphics

public enum AvatarRecolorEngine {
    /// 只替换原始头像的基底背景色，严格保留薄荷绿眼白与深棕瞳孔/嘴巴的原始颜色。
    /// 通过边界过渡平滑插值消除切换底色后的紫边/杂色光晕。
    public static func recolorBase(
        source: CGImage,
        target: AvatarColorVariant
    ) -> CGImage? {
        let width = source.width
        let height = source.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 自动采样四角基底背景色（容错 JPEG 压缩微差）
        let (bgR, bgG, bgB) = sampleCornerBackground(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)

        let tR = Double(target.red)
        let tG = Double(target.green)
        let tB = Double(target.blue)

        // 原图背景色 (86,89,201) 到薄荷绿眼白 (170,240,192) 距离约 173，到深棕瞳孔 (48,36,23) 距离约 190
        let innerThreshold: Double = 32.0
        let outerThreshold: Double = 88.0
        let deltaR = tR - bgR
        let deltaG = tG - bgG
        let deltaB = tB - bgB

        let totalPixels = width * height
        for i in 0..<totalPixels {
            let offset = i * 4
            let r = Double(pixels[offset])
            let g = Double(pixels[offset + 1])
            let b = Double(pixels[offset + 2])

            let dr = r - bgR
            let dg = g - bgG
            let db = b - bgB
            let dist = sqrt(dr * dr + dg * dg + db * db)

            if dist <= innerThreshold {
                pixels[offset]     = target.red
                pixels[offset + 1] = target.green
                pixels[offset + 2] = target.blue
            } else if dist < outerThreshold {
                // 平滑反混叠：按背景占比将原背景分量替换为目标底色，保留前景眼睛/嘴巴
                let t = (dist - innerThreshold) / (outerThreshold - innerThreshold)
                let bgWeight = 1.0 - t
                pixels[offset]     = clampByte(r + bgWeight * deltaR)
                pixels[offset + 1] = clampByte(g + bgWeight * deltaG)
                pixels[offset + 2] = clampByte(b + bgWeight * deltaB)
            }
            // dist >= outerThreshold：眼睛和嘴巴像素 100% 保持原样不变
        }

        return ctx.makeImage()
    }

    public static func generateTenVariants(from source: CGImage) -> [CGImage] {
        AvatarColorVariant.tenVariants.compactMap { variant in
            recolorBase(source: source, target: variant)
        }
    }

    private static func sampleCornerBackground(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> (Double, Double, Double) {
        let marginX = min(8, max(0, width - 1))
        let marginY = min(8, max(0, height - 1))
        let coords = [
            (marginX, marginY),
            (max(0, width - 1 - marginX), marginY),
            (marginX, max(0, height - 1 - marginY)),
            (max(0, width - 1 - marginX), max(0, height - 1 - marginY))
        ]
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        for (x, y) in coords {
            let off = y * bytesPerRow + x * 4
            sumR += Double(pixels[off])
            sumG += Double(pixels[off + 1])
            sumB += Double(pixels[off + 2])
        }
        let n = Double(coords.count)
        return (sumR / n, sumG / n, sumB / n)
    }

    @inline(__always)
    private static func clampByte(_ value: Double) -> UInt8 {
        if value <= 0 { return 0 }
        if value >= 255 { return 255 }
        return UInt8(value.rounded())
    }
}
