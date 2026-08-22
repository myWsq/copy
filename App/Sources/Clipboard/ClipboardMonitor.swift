import AppKit

/// 轮询 `NSPasteboard.general.changeCount` 捕获复制事件。
///
/// macOS 至今没有剪贴板变更通知，轮询是唯一途径 —— Paste、Maccy、Alfred 全都这么做。
/// 0.35s 是体感即时与空转开销之间的折中：变更检测只读一个整数，开销可忽略，
/// 只有 changeCount 真的变了才去解析内容。
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    /// 阻止 App Nap 的活动令牌，必须持有到停止监听为止。
    private var activity: NSObjectProtocol?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// 自己写入剪贴板（粘贴时）会抬高 changeCount，需要跳过以免把粘贴当成复制记录下来。
    private var suppressedChangeCount = -1

    var excludedBundleIDs: Set<String> = []
    var onCapture: ((ClipItem) -> Void)?

    func start(interval: TimeInterval = 0.35) {
        timer?.invalidate()

        // macOS 会对后台的 LSUIElement 应用启用 App Nap，把定时器节流甚至挂起 ——
        // 表现就是「刚启动能记录，用一会儿就不记录了」，且没有任何报错。剪贴板管理器
        // 必须持续轮询，这里显式声明一段持续的后台活动来豁免。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .background],
            reason: "Clipboard monitoring")

        // 用 .common 模式而不是 scheduledTimer 的默认 .default ——
        // 后者在菜单弹出、窗口拖拽等事件跟踪期间会暂停，那段时间的复制会被漏掉。
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.clipboard.notice("monitor started, interval=\(interval), changeCount=\(self.lastChangeCount)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// 在自行写入剪贴板前调用，避免回环捕获。
    func suppressNextChange() {
        suppressedChangeCount = NSPasteboard.general.changeCount + 1
    }

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        Log.clipboard.debug("changeCount \(self.lastChangeCount) -> \(count)")
        lastChangeCount = count
        guard count != suppressedChangeCount else {
            Log.clipboard.notice("skip: suppressed (self-paste)")
            return
        }

        let source = NSWorkspace.shared.frontmostApplication
        if let id = source?.bundleIdentifier, excludedBundleIDs.contains(id) {
            Log.clipboard.notice("skip: excluded app \(id, privacy: .public)")
            return
        }
        guard let item = PasteboardReader.read(pb, source: source, blobsURL: ClipStore.shared.blobsURL) else {
            Log.clipboard.notice("skip: reader nil, types=\(pb.types?.map(\.rawValue).joined(separator: ",") ?? "none", privacy: .public)")
            return
        }
        Log.clipboard.debug("captured \(item.kind.rawValue, privacy: .public) from \(item.sourceAppName ?? "?", privacy: .public)")
        onCapture?(item)
    }
}
