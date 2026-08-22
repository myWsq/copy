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
        panel.warmUp()

        monitor.onCapture = { item in
            do {
                try ClipStore.shared.insert(item)
                Log.store.debug("inserted \(item.kind.rawValue, privacy: .public)")
            } catch {
                Log.store.error("insert failed: \(error, privacy: .public)")
            }
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

        #if DEBUG
        // 自动化测试用的触发钩子：热键会和别的剪贴板工具抢，菜单栏图标的坐标又不总能
        // 查到，测试需要一条稳定的路径。只在 Debug 构建里存在 —— 发布版留着等于让任何
        // 本机进程都能弹出用户的剪贴板历史。
        DistributedNotificationCenter.default().addObserver(
            forName: .init("dev.copyapp.Copy.togglePanel"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.toggle() }
        }
        #endif

        setUpMainMenu()
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

    /// 装一个只含「编辑」的主菜单。
    ///
    /// macOS 的标准编辑快捷键（⌘A/⌘C/⌘V/⌘X/⌘Z）是靠主菜单里的菜单项分发的，
    /// 而 `LSUIElement` 应用默认没有主菜单 —— 结果就是搜索框里按 ⌘A 毫无反应
    /// （事件被转成 noop）。菜单本身不会显示，因为面板是非激活的，App 不会成为前台。
    private func setUpMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
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
