import AppKit
import SwiftUI

/// 底部剪贴板条。几何取自对 Paste 6.6.8 截图的像素测量（见 CLAUDE.md「参考原作」）。
struct ClipboardBarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            cards
        }
    }

    /// 把导航类按键从搜索框里截出来交给卡片列表；其余（含输入法组字）留给文本框。
    private func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveUp(_:)):
            state.move(by: -1)
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveDown(_:)):
            state.move(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            state.onPaste?(false)
        case #selector(NSResponder.insertLineBreak(_:)):            // ⇧↩
            state.onPaste?(true)
        case #selector(NSResponder.cancelOperation(_:)):            // esc
            state.onDismiss?()
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):    // ⌘⌫
            state.deleteSelected()
        default:
            return false    // 其余按键归文本框，退格才能正常删字
        }
        return true
    }

    // MARK: - 工具栏

    /// 原作的标签组是居中的，搜索折叠成一个放大镜图标。
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            // 搜索框始终在视图树里（否则拿不到键盘焦点），仅在有内容时展开可见。
            SearchField(text: $state.query, onCommand: handleCommand)
                .frame(width: state.query.isEmpty ? 1 : 170, height: 16)
                .opacity(state.query.isEmpty ? 0 : 1)

            PinboardTab(title: Localized.clipboard, symbol: "clock.arrow.circlepath", tint: nil,
                        isActive: state.activePinboardID == nil) { state.activePinboardID = nil }
            ForEach(state.pinboards) { board in
                PinboardTab(title: board.name, symbol: "circle.fill", tint: .accentColor,
                            isActive: state.activePinboardID == board.id) { state.activePinboardID = board.id }
            }
            Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: state.query.isEmpty)
    }

    // MARK: - 卡片流

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ClipCard.gap) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        ClipCard(item: item, index: index, isSelected: index == state.selection)
                            .id(index)
                            .onTapGesture { state.selection = index }
                    }
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: state.selection) { _, new in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(new, anchor: .center) }
            }
            .overlay {
                if state.items.isEmpty {
                    ContentUnavailableView(state.query.isEmpty ? "Nothing copied yet" : "No matches",
                                           systemImage: "doc.on.clipboard")
                }
            }
        }
        .frame(height: ClipCard.size.height)
        .padding(.bottom, 34)
    }
}

private struct PinboardTab: View {
    let title: String, symbol: String
    let tint: Color?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint ?? .secondary)
                Text(title).font(.system(size: 13))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(isActive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 单张剪贴板卡片：彩色顶栏（取自来源 App 图标主色）+ 内容 + 底栏元信息。
struct ClipCard: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool

    static let size = CGSize(width: 235, height: 234)
    static let gap: CGFloat = 21
    private static let headerHeight: CGFloat = 50
    private static let radius: CGFloat = 12

    private var accent: Color { Color(AppAccent.color(forBundleID: item.sourceBundleID)) }
    /// 选中时整个内容区反色成白底，这是原作最醒目的选中反馈。
    ///
    /// 未选中态用 `underPageBackgroundColor`（深色下 #282828）而不是 `windowBackgroundColor`
    /// （#1E1E1E）—— 卡片浮在玻璃之上，需要比"窗口底"更亮一档才立得起来。用语义色而非硬编码
    /// 数值，才能跟随浅/深色模式与「增强对比度」辅助功能设置。
    private var surface: Color { isSelected ? .white : Color(nsColor: .underPageBackgroundColor) }
    private var ink: Color { isSelected ? .black : .white }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            // 未选中也描一圈 separatorColor（系统标准的 white@10%），在通透的玻璃上切出边界，
            // 这样就不必靠加深玻璃 tint 来换对比 —— 后者反而会让深色卡片陷进背景里。
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: isSelected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    private var header: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text(item.createdAt.relativeDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            Spacer(minLength: 4)
            if let icon = AppAccent.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: 46, height: 46)
            }
        }
        .padding(.leading, 12)
        .frame(height: Self.headerHeight)
        .background(accent)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch item.kind {
            case .image:
                if let blob = item.blobPath,
                   let image = NSImage(contentsOf: ClipStore.shared.blobsURL.appendingPathComponent(blob)) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    symbolPlaceholder
                }
            case .file:
                VStack(spacing: 6) {
                    Image(systemName: "doc.fill").font(.system(size: 34)).foregroundStyle(ink.opacity(0.5))
                    Text((item.text.split(separator: "\n").first?.split(separator: "/").last).map(String.init) ?? "")
                        .font(.system(size: 12)).foregroundStyle(ink).lineLimit(2)
                }
            case .color:
                Rectangle().fill(Color(hex: item.text) ?? .gray)
            default:
                Text(item.text)
                    .font(.system(size: adaptiveFontSize, weight: adaptiveFontSize > 20 ? .regular : .regular,
                                  design: item.kind == .link ? .default : .default))
                    .foregroundStyle(ink)
                    .lineLimit(adaptiveFontSize > 20 ? 3 : 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14).padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// 原作会按内容长短放大字号 —— 复制一个验证码时它显示得很大，很好认。
    private var adaptiveFontSize: CGFloat {
        switch item.text.count {
        case 0...12: 30
        case 13...40: 16
        default: 13
        }
    }

    private var symbolPlaceholder: some View {
        Image(systemName: item.kind.symbol).font(.largeTitle).foregroundStyle(ink.opacity(0.4))
    }

    /// 底栏：次要信息居中，序号靠右 —— 与原作一致。
    private var footer: some View {
        ZStack {
            Text(item.footerText)
            HStack { Spacer(); Text("\(index + 1)") }
        }
        .font(.system(size: 12))
        .foregroundStyle(ink.opacity(0.45))
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

// MARK: - 展示用格式化

extension ClipItem {
    /// 文本类显示字符数，其余显示捕获时算好的 `meta`。
    var footerText: String {
        if let meta { return meta }
        return Localized.characters(text.count)
    }
}

extension Date {
    var relativeDescription: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: self, relativeTo: Date())
    }
}

/// 轻量本地化。TODO: 条目变多后换成 String Catalog（.xcstrings）。
enum Localized {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }

    static var clipboard: String { isChinese ? "剪贴板" : "Clipboard" }

    static func characters(_ n: Int) -> String {
        isChinese ? "\(n) 个字符" : (n == 1 ? "1 character" : "\(n) characters")
    }

    static func kind(_ kind: ClipKind) -> String {
        guard isChinese else {
            switch kind {
            case .text: return "Text"
            case .richText: return "Rich Text"
            case .link: return "Link"
            case .image: return "Image"
            case .file: return "File"
            case .color: return "Color"
            }
        }
        switch kind {
        case .text: return "文本"
        case .richText: return "富文本"
        case .link: return "链接"
        case .image: return "图片"
        case .file: return "文件"
        case .color: return "颜色"
        }
    }
}

extension ClipKind {
    var displayName: String { Localized.kind(self) }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .richText: "doc.richtext"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }
}

extension Color {
    /// 解析 `#RRGGBB` / `#RRGGBBAA`，用于 color 类型卡片预览。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard let value = UInt32(s, radix: 16), s.count == 6 || s.count == 8 else { return nil }
        let hasAlpha = s.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
