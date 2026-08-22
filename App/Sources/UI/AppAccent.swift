import AppKit
import SwiftUI

/// 从来源 App 的图标里提取主色 —— 卡片顶栏用它着色。
///
/// 这是 Paste 最好认的视觉特征：终端的卡片是黑顶，微信是绿顶，Safari 是蓝顶。
/// 直接把图标缩到 1×1 取平均是不行的：Chrome 图标红黄绿蓝各占一块，平均下来是脏灰色。
/// 这里按「饱和度加权投票」，让面积大且鲜艳的颜色胜出；若整张图都不鲜艳（终端那种黑图标），
/// 再退回按亮度取灰阶，于是黑图标仍得到黑顶。
enum AppAccent {
    /// 缓存的是 SwiftUI 的 `Color` 而不是 `NSColor` —— 每次 `Color(nsColor:)` 都要做一次
    /// 颜色空间转换，而这个值在每张卡片的 body 里都会被读到，卡片一多就是几百次。
    private static var cache: [String: Color] = [:]
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

    static func color(forBundleID bundleID: String?) -> Color {
        guard let bundleID else { return Palette.fallbackAccent }
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return Palette.fallbackAccent
        }
        let color = Color(dominant(in: NSWorkspace.shared.icon(forFile: url.path)) ?? .darkGray)
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



/// 卡片上反复用到的语义色。
///
/// `Color(nsColor:)` 每次都要做颜色空间转换，而这些值在每张卡片的 body 里都会被读到 ——
/// 面板固定 darkAqua 外观（见 PastePanel），它们不会变，缓存成常量即可。
/// 只有强调色留成计算属性：用户随时可能在系统设置里换它。
enum Palette {
    static let surface = Color(nsColor: .underPageBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let fallbackAccent = Color(nsColor: .darkGray)
    static var systemAccent: Color { Color(nsColor: .controlAccentColor) }
}


/// 收藏夹可选的颜色。顺序与原作一致：红、橙、黄、绿、蓝、紫、粉、灰。
///
/// 用系统色而不是自己调的十六进制 —— 它们在深色模式和「增强对比度」下都由系统负责调整。
enum PinboardPalette {
    static let nsColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .systemPink, .systemGray,
    ]
    static let colors: [Color] = nsColors.map(Color.init)

    private static var dotCache: [Int: NSImage] = [:]

    static func color(_ index: Int) -> Color {
        colors[clamp(index)]
    }

    /// 收藏夹色顶栏上的文字色：亮底（黄）用深色，其余用白。
    ///
    /// 白字压在 systemYellow 上读不出来，Paste 在黄底上同样换成深色文字。按 luminance
    /// 一次算好缓存 —— 调色板是固定的，逐次算没有意义。
    private static let headerInks: [Color] = nsColors.map { color in
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma > 0.7 ? Color.black.opacity(0.85) : .white
    }

    static func headerInk(_ index: Int) -> Color {
        headerInks[clamp(index)]
    }

    static func nsColor(_ index: Int) -> NSColor {
        nsColors[clamp(index)]
    }

    private static func clamp(_ index: Int) -> Int {
        max(0, min(index, nsColors.count - 1))
    }

    /// 菜单项用的彩色小圆点。
    ///
    /// 必须自己画成 `NSImage` 并把 `isTemplate` 置为 false —— SwiftUI 的
    /// `Label { } icon: { Image(systemName:).foregroundStyle(...) }` 放进 macOS 菜单会被
    /// 当作模板图渲染，颜色整个丢掉，只剩个灰点甚至什么都不显示。
    static func dotImage(_ index: Int) -> NSImage {
        let key = clamp(index)
        if let hit = dotCache[key] { return hit }
        let side: CGFloat = 10
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        nsColors[key].setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        image.unlockFocus()
        image.isTemplate = false
        dotCache[key] = image
        return image
    }

    static func name(_ index: Int, chinese: Bool) -> String {
        let zh = ["红", "橙", "黄", "绿", "蓝", "紫", "粉", "灰"]
        let en = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Gray"]
        let i = max(0, min(index, zh.count - 1))
        return chinese ? zh[i] : en[i]
    }
}
