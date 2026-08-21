import AppKit

/// 轮询 `NSPasteboard.general.changeCount` 捕获复制事件。
///
/// macOS 至今没有剪贴板变更通知，轮询是唯一途径 —— Paste、Maccy、Alfred 全都这么做。
/// 0.35s 是体感即时与空转开销之间的折中：变更检测只读一个整数，开销可忽略，
/// 只有 changeCount 真的变了才去解析内容。
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// 自己写入剪贴板（粘贴时）会抬高 changeCount，需要跳过以免把粘贴当成复制记录下来。
    private var suppressedChangeCount = -1

    var excludedBundleIDs: Set<String> = []
    var onCapture: ((ClipItem) -> Void)?

    func start(interval: TimeInterval = 0.35) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 在自行写入剪贴板前调用，避免回环捕获。
    func suppressNextChange() {
        suppressedChangeCount = NSPasteboard.general.changeCount + 1
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard pb.changeCount != suppressedChangeCount else { return }

        let source = NSWorkspace.shared.frontmostApplication
        if let id = source?.bundleIdentifier, excludedBundleIDs.contains(id) {
            Log.clipboard.debug("skip: excluded app \(id)")
            return
        }
        guard let item = PasteboardReader.read(pb, source: source, blobsURL: ClipStore.shared.blobsURL) else { return }
        onCapture?(item)
    }
}
