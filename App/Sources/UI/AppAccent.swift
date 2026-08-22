import AppKit

/// 从来源 App 的图标里提取主色 —— 卡片顶栏用它着色。
///
/// 这是 Paste 最好认的视觉特征：终端的卡片是黑顶，微信是绿顶，Safari 是蓝顶。
/// 直接把图标缩到 1×1 取平均是不行的：Chrome 图标红黄绿蓝各占一块，平均下来是脏灰色。
/// 这里按「饱和度加权投票」，让面积大且鲜艳的颜色胜出；若整张图都不鲜艳（终端那种黑图标），
/// 再退回按亮度取灰阶，于是黑图标仍得到黑顶。
enum AppAccent {
    private static var cache: [String: NSColor] = [:]
    private static var iconCache: [String: NSImage] = [:]

    /// 来源 App 的图标，按 bundle ID 缓存 —— 每帧去 NSWorkspace 查会拖垮滚动。
    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = iconCache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    static func color(forBundleID bundleID: String?) -> NSColor {
        guard let bundleID else { return .darkGray }
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return .darkGray
        }
        let color = dominant(in: NSWorkspace.shared.icon(forFile: url.path)) ?? .darkGray
        cache[bundleID] = color
        return color
    }

    static func dominant(in image: NSImage) -> NSColor? {
        let side = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: side * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var best: (color: NSColor, score: CGFloat) = (.darkGray, -1)
        var lumaSum: CGFloat = 0, lumaCount: CGFloat = 0

        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.4 else { continue }
                let rgb = c.usingColorSpace(.deviceRGB) ?? c
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                lumaSum += b; lumaCount += 1
                // 太亮太白（图标底色）或太暗的像素不参与彩色投票
                guard s > 0.35, b > 0.25 else { continue }
                let score = s * b
                if score > best.score { best = (rgb, score) }
            }
        }

        if best.score > 0 { return best.color }
        // 全是灰阶图标（终端、Xcode 深色图标）：按平均亮度还原成对应的灰。
        guard lumaCount > 0 else { return nil }
        let luma = min(lumaSum / lumaCount, 0.35)
        return NSColor(deviceWhite: luma, alpha: 1)
    }
}

