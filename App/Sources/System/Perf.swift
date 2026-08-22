import AppKit
import QuartzCore
import os

/// 性能埋点。默认关闭，开启：`defaults write dev.copyapp.Copy perfLog -bool YES`
///
/// 存在的理由：靠 `sample` 抓调用栈只能看出"热点大概在哪一层"，分不清是打开面板慢还是
/// 滚动掉帧，也给不出毫秒数。这里直接量两件事 —— 关键路径耗时、以及显示期间的掉帧。
enum Perf {
    nonisolated(unsafe) static let enabled = UserDefaults.standard.bool(forKey: "perfLog")
    static let log = Logger(subsystem: "dev.copyapp.Copy", category: "perf")

    @discardableResult
    static func time<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        let ms = (CACurrentMediaTime() - start) * 1000
        log.notice("⏱ \(label, privacy: .public) \(ms, format: .fixed(precision: 2))ms")
        return result
    }
}

/// 统计面板显示期间的帧间隔，找出掉帧。
///
/// 屏幕 60Hz 时每帧 16.7ms；超过 33ms 说明至少丢了一帧，用户能直接感觉到卡。
@MainActor
final class FrameMonitor {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var worst: Double = 0
    private var totalMS: Double = 0

    func start(in view: NSView) {
        guard Perf.enabled else { return }
        Perf.log.notice("🎬 FrameMonitor.start, view.window=\(view.window != nil)")
        stop(label: nil)
        frames = 0; hitches = 0; worst = 0; totalMS = 0; last = 0
        let link = view.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else { return }
        let delta = (now - last) * 1000
        frames += 1
        totalMS += delta
        worst = max(worst, delta)
        if delta > 33 { hitches += 1 }
    }

    func stop(label: String?) {
        link?.invalidate()
        link = nil
        guard Perf.enabled, let label else { return }
        guard frames > 0 else { Perf.log.notice("📊 \(label, privacy: .public) 未收到任何帧回调"); return }
        let avg = totalMS / Double(frames)
        Perf.log.notice("""
            📊 \(label, privacy: .public) 帧数 \(self.frames) · 平均 \(avg, format: .fixed(precision: 1))ms \
            · 最差 \(self.worst, format: .fixed(precision: 1))ms · 掉帧 \(self.hitches)
            """)
    }
}

