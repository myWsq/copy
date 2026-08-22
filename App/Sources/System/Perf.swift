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

    /// 量「从此刻到主线程下一次空闲」。
    ///
    /// 单点计时罩不住 @Observable 的失效传播 —— 改状态只是打标记，SwiftUI 真正的重新求值、
    /// 布局与 CA 提交发生在本轮 runloop 稍后。observer 的 order 放在 CA 提交观察者
    /// （order 2_000_000）之后，同一轮 beforeWaiting 里能把提交耗时也量进去，
    /// 这个数字才对应用户感到的那一下卡顿。
    static func stallProbe(_ label: String) {
        guard enabled else { return }
        let start = CACurrentMediaTime()
        let logger = log
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, 3_000_000
        ) { @Sendable _, _ in
            let ms = (CACurrentMediaTime() - start) * 1000
            logger.notice("⏱ \(label, privacy: .public) → 主线程空闲 \(ms, format: .fixed(precision: 2))ms")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
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

