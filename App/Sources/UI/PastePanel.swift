import AppKit
import SwiftUI

/// 承载剪贴板条的悬浮面板。
///
/// `.nonactivatingPanel` 是关键：面板能成为 key window 接收键盘，却不会把 Copy 变成前台 App。
/// 因此 `NSWorkspace.frontmostApplication` 在面板可见时仍指向用户原本的 App，
/// 粘贴时无需保存/恢复任何状态。普通 NSWindow 做不到这一点。
@MainActor
final class PastePanel: NSPanel {
    private let state: AppState
    private var monitor: ClipboardMonitor?

    /// Paste 的条形面板贴屏幕底边通栏。
    private static let panelHeight: CGFloat = 332
    /// 原作没有贴死屏幕边缘，四周留了一圈窄边并带圆角。
    private static let inset: CGFloat = 8
    private static let cornerRadius: CGFloat = 16
    private static let defaultTint: Double = 0.15

    init(state: AppState, monitor: ClipboardMonitor?) {
        self.state = state
        self.monitor = monitor
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        // 固定深色主题：卡片「选中时反白」的设计依赖深色底衬托，跟随系统切到浅色会让
        // 选中态和普通态难以区分。系统 HUD 类浮层（Spotlight 等）同样固定外观。
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        animationBehavior = .none

        // macOS 26 的 Liquid Glass。整个面板是一层浮在桌面之上的玻璃 —— 这正是这个材质
        // 被设计出来的用途。注意必须走 `contentView` 属性而不是 addSubview：头文件明确说
        // 只有 contentView 保证被放进玻璃效果内，其它子视图的 z-order 行为不作保证。
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        // Liquid Glass 比传统毛玻璃透得多，背景杂乱时卡片间隙会花。用一点深色 tint 压对比。
        // 强度可调（设置窗口迟早要暴露它）：`defaults write dev.copyapp.Copy glassTint 0.3`
        let tint = UserDefaults.standard.object(forKey: "glassTint") as? Double ?? Self.defaultTint
        if tint > 0 { glass.tintColor = NSColor(white: 0, alpha: tint) }
        glass.contentView = NSHostingView(rootView: ClipboardBarView(state: state))
        contentView = glass

        state.onPaste = { [weak self] plain in self?.pasteSelected(plainText: plain) }
        state.onDismiss = { [weak self] in self?.hide() }
    }

    override var canBecomeKey: Bool { true }

    // MARK: - 显隐

    func toggle() { isVisible ? hide() : show() }

    func show() {
        state.previousApp = NSWorkspace.shared.frontmostApplication
        state.reload()
        state.selection = 0

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let end = NSRect(x: visible.minX + Self.inset, y: visible.minY + Self.inset,
                         width: visible.width - Self.inset * 2, height: Self.panelHeight)
        setFrame(end.offsetBy(dx: 0, dy: -Self.panelHeight), display: false)
        alphaValue = 0
        orderFrontRegardless()
        makeKey()

        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.22
            $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(end, display: true)
            animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // completionHandler 的类型签名是 nonisolated，但 AppKit 保证它在主线程回调。
            // macOS 26 SDK 收紧了并发标注，这里必须显式断言，否则报 actor 隔离警告。
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }

    // MARK: - 键盘

    // 方向键 / 回车 / esc 由 SearchField 截获后转发（见 ClipboardBarView.handleCommand），
    // 这样输入法能正常工作。这里只兜住搜索框未持有焦点时的情况。
    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 123: state.move(by: -1)
        case 124: state.move(by: 1)
        case 53: hide()
        case 36, 76: pasteSelected(plainText: event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    /// ⌘1…⌘9 快速粘贴第 N 项。走 keyEquivalent 而非 keyDown —— 带 ⌘ 的按键会先经过
    /// 这条链路，若等到 keyDown 已被文本框吃掉。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let n = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(n),
              state.items.indices.contains(n - 1)
        else { return super.performKeyEquivalent(with: event) }
        state.selection = n - 1
        pasteSelected(plainText: false)
        return true
    }

    /// 面板失焦（用户点了别处）即收起，与 Paste 行为一致。
    override func resignKey() {
        super.resignKey()
        hide()
    }

    func pasteSelected(plainText: Bool) {
        guard let item = state.selectedItem else { return }
        Paster.paste(item, to: state.previousApp, plainText: plainText, monitor: monitor) { [weak self] in
            self?.orderOut(nil)
        }
    }
}
