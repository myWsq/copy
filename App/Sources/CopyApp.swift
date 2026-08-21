import AppKit
import Carbon.HIToolbox

@main
enum CopyApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 菜单栏常驻，不占 Dock
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let monitor = ClipboardMonitor()
    private var panel: PastePanel!
    private var hotKey: HotKey?
    private var activeShortcut = "—"
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    /// 按优先级尝试的热键。⇧⌘V 是原作的默认键，但它可能已被别的剪贴板管理器
    /// （包括 Paste 本身）占用 —— `RegisterEventHotKey` 此时返回 `eventHotKeyExistsErr`
    /// 且**不会**有任何运行时报错，表现为「热键就是没反应」。所以要逐个回退。
    private static let shortcutCandidates: [(key: UInt32, mods: UInt32, label: String)] = [
        (UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), "⇧⌘V"),
        (UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey), "⌥⌘V"),
        (UInt32(kVK_ANSI_V), UInt32(cmdKey | controlKey | shiftKey), "⌃⇧⌘V"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PastePanel(state: state, monitor: monitor)

        monitor.onCapture = { item in
            do { try ClipStore.shared.insert(item) } catch { Log.store.error("insert: \(error)") }
        }
        monitor.start()

        for candidate in Self.shortcutCandidates {
            if let registered = HotKey(keyCode: candidate.key, modifiers: candidate.mods,
                                       handler: { [weak self] in self?.panel.toggle() }) {
                hotKey = registered
                activeShortcut = candidate.label
                break
            }
        }
        if hotKey == nil { Log.system.error("所有候选热键都被占用") }
        Log.system.notice("热键已注册: \(self.activeShortcut, privacy: .public)")

        setUpStatusItem()

        // 刻意不在启动时调用 requestAccessibility() —— 那会弹出系统授权对话框。
        // 每次重新编译，ad-hoc 签名的 cdhash 都会变，macOS 认为是另一个 App、授权作废，
        // 于是开发期每启动一次就弹一次。何况启动即索权本身就是糟糕的设计。
        // 改为：静默检查，把授权入口留在菜单栏菜单里；没权限时 Paster 已有降级路径。
        if !Permissions.hasAccessibility {
            Log.system.notice("辅助功能权限未授予 —— 可从菜单栏菜单手动开启，粘贴将降级为仅写剪贴板")
        }
        try? ClipStore.shared.prune(olderThan: 30)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copy")

        statusMenu.addItem(withTitle: "Show Clipboard  \(activeShortcut)", action: #selector(togglePanel), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Accessibility Permission…", action: #selector(openAccessibility), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Copy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusMenu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? nil : self }

        // 刻意不设 `statusItem.menu` —— 一旦设了，左键点击只会弹菜单，button 的 action 永远收不到，
        // 就没法做「左键唤起面板、右键弹菜单」的分流。改为自己接管点击并按事件类型分发。
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { panel.toggle(); return }
        // 右键，或 Control-左键（macOS 上等价于右键）→ 菜单；普通左键 → 直接唤起面板。
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            panel.toggle()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        // 用 NSMenu.popUp 而不是给 statusItem 挂 menu —— 后者需要挂上再摘掉，中间那一瞬
        // 左键也会变成弹菜单。
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }

    @objc private func togglePanel() { panel.toggle() }

    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
