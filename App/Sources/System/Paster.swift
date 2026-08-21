import AppKit
import Carbon.HIToolbox

/// 把条目送回用户刚才所在的 App。
///
/// 这条链路是整个 App 最脆弱的地方，顺序不能变：
/// 写剪贴板 → 收起面板 → 激活目标 App → 等它真的拿到焦点 → 合成 ⌘V。
/// 少了「等」这一步，按键会打在还没让出焦点的窗口上，表现为「粘贴偶尔不生效」。
@MainActor
enum Paster {
    /// 系统需要一点时间完成 App 激活与焦点转移。80ms 是实测下限，低于此在慢机器上会丢键。
    private static let activationDelay: Duration = .milliseconds(80)

    static func paste(_ item: ClipItem, to target: NSRunningApplication?, plainText: Bool = false,
                      monitor: ClipboardMonitor?, onFinish: (() -> Void)? = nil) {
        monitor?.suppressNextChange()
        write(item, plainText: plainText)

        Task { @MainActor in
            onFinish?()
            target?.activate()
            try? await Task.sleep(for: activationDelay)
            synthesizeCommandV()
        }
    }

    /// 只把内容放进剪贴板，不模拟按键（无辅助功能权限时的降级路径）。
    static func write(_ item: ClipItem, plainText: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .image:
            if let blob = item.blobPath,
               let data = try? Data(contentsOf: ClipStore.shared.blobsURL.appendingPathComponent(blob)),
               let image = NSImage(data: data) {
                pb.writeObjects([image])
                return
            }
        case .file:
            let urls = item.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            if !urls.isEmpty { pb.writeObjects(urls); return }
        case .richText where !plainText:
            if let blob = item.blobPath,
               let rtf = try? Data(contentsOf: ClipStore.shared.blobsURL.appendingPathComponent(blob)) {
                pb.setData(rtf, forType: .rtf)
            }
        default:
            break
        }
        pb.setString(item.text, forType: .string)
    }

    /// 合成一次 ⌘V。需要「辅助功能」权限，否则事件会被系统静默丢弃。
    private static func synthesizeCommandV() {
        guard Permissions.hasAccessibility else {
            Log.system.notice("paste skipped: no accessibility permission")
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

@MainActor
enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权提示。用户点「打开系统设置」后需要手动勾选，无法程序化授予。
    static func requestAccessibility() {
        // 用字面量而非 kAXTrustedCheckOptionPrompt：该全局是可变 var，在 Swift 6 下不是并发安全的。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
