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
    /// 真正承载界面的玻璃层。它只占窗口的上半部分，下半部分是留给滑出动画的空间。
    private var glassView: NSGlassEffectView!
    private var hostingView: NSHostingView<ClipboardBarView>!
    /// 用户意图上的显示状态。**不要用 `isVisible` 代替** —— 那反映的是窗口此刻在不在屏上，
    /// 动画播放期间两者是脱节的：滑出还没播完窗口仍 visible，于是连点会走错分支。
    private var isPresented = false
    private let frames = FrameMonitor()

    /// Paste 的条形面板贴屏幕底边通栏。
    private static let panelHeight: CGFloat = 332
    /// 原作没有贴死屏幕边缘，四周留了一圈窄边并带圆角。
    private static let inset: CGFloat = 8
    private static let cornerRadius: CGFloat = 16
    /// 滑动位移必须是「面板高 + 下边距」而不只是面板高 —— 面板顶边距屏幕底还有 inset 那么远，
    /// 只走 panelHeight 的话顶边会停在屏幕内，留下一条，然后被 orderOut 硬切掉。
    private static var travel: CGFloat { panelHeight + inset }
    // 动画用弹簧而非 duration + 贝塞尔曲线：系统自 macOS 14 起的面板动效都是物理模型，
    // 贝塞尔怎么调都差一口气。`perceptualDuration` 是"感觉上多久"，实际稳定时间由刚度和
    // 阻尼算出（settlingDuration）；`bounce` 为 0 是临界阻尼、不回弹，大于 0 会过冲再收回。
    private static let showDuration: CFTimeInterval = 0.42
    private static let showBounce: CGFloat = 0.20   // 滑入带一点过冲，面板"迎上来"有质量感
    /// 留给弹簧过冲的余量。bounce 会让内容冲过目标位置再收回，玻璃层顶边原本就贴着窗口
    /// 顶边，不留这块空间就会在过冲的瞬间被窗口裁掉一条。按位移 × bounce 再放宽一倍取整。
    private static var overshootRoom: CGFloat { (travel * showBounce * 2).rounded(.up) }
    private static let hideDuration: CFTimeInterval = 0.32
    private static let hideBounce: CGFloat = 0      // 滑出不回弹，干脆离开
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
        hasShadow = false   // 无边框透明窗口的阴影会沿边缘糊成一圈黑框；玻璃自带边缘光
        level = .statusBar
        // ignoresCycle：窗口收起后只是挪到屏幕外而非 orderOut，不能让它出现在 ⌘` 循环里
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true   // 工具栏按钮要靠它响应悬停
        animationBehavior = .none

        // macOS 26 的 Liquid Glass。整个面板是一层浮在桌面之上的玻璃 —— 这正是这个材质
        // 被设计出来的用途。注意必须走 `contentView` 属性而不是 addSubview：头文件明确说
        // 只有 contentView 保证被放进玻璃效果内，其它子视图的 z-order 行为不作保证。
        // 窗口做成两倍面板高、下沿伸到屏幕外，玻璃层只占上半部分。这样内容往下滑时
        // 是真的滑出屏幕，而不是滑到窗口边界就被裁掉 —— 后者看起来像"在底边被截断"。
        let container = NSView()
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        // Liquid Glass 比传统毛玻璃透得多，背景杂乱时卡片间隙会花。用一点深色 tint 压对比。
        // 强度可调（设置窗口迟早要暴露它）：`defaults write dev.copyapp.Copy glassTint 0.3`
        let tint = UserDefaults.standard.object(forKey: "glassTint") as? Double ?? Self.defaultTint
        if tint > 0 { glass.tintColor = NSColor(white: 0, alpha: tint) }
        let hosting = NSHostingView(rootView: ClipboardBarView(state: state))
        // 面板尺寸是外部定死的，不需要 hosting view 按内容反推自身大小。
        // 留着默认值会让每次内容变化都向上传播一轮 NSView 布局（采样里
        // NSPerformVisuallyAtomicChange / _layoutSubtreeWithOldSize 的来源）。
        hosting.sizingOptions = []
        hostingView = hosting
        glass.contentView = hosting
        container.addSubview(glass)
        glassView = glass
        contentView = container

        state.onPaste = { [weak self] plain in self?.pasteSelected(plainText: plain) }
        state.onDismiss = { [weak self] in self?.hide() }
    }

    override var canBecomeKey: Bool { true }

    /// 面板该出现在哪块屏幕。
    ///
    /// **不要用 `NSScreen.main`** —— 它的语义是"包含 key window 的那块屏"，而这是个
    /// 非激活的 accessory 应用，唤起的瞬间既不是前台也还没有 key window，它会返回 nil，
    /// 于是 `guard` 直接让 show() 静默退出：面板不上屏、不 makeKey，按键全部落空，
    /// 而且一句报错都没有。改成先按鼠标位置选屏（顺带支持多显示器），再层层兜底。
    private var targetScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }


    /// 启动时把 orderFront 的一次性开销先付掉。
    ///
    /// 首次 orderFront 要建立近全屏窗口的后备存储、初始化 Liquid Glass 的采样，实测 ~230ms。
    /// 不预热的话这笔账会记在用户第一次按热键上。这里用 alpha 0 上屏、下一轮 runloop 立刻
    /// 挪到屏幕外，整个过程不可见。
    func warmUp() {
        guard let screen = targetScreen else { return }
        let width = screen.frame.width - Self.inset * 2
        alphaValue = 0
        setFrame(NSRect(x: screen.frame.minX + Self.inset, y: screen.frame.minY - Self.travel,
                        width: width,
                        height: Self.panelHeight + Self.travel + Self.overshootRoom), display: false)
        glassView.frame = NSRect(x: 0, y: Self.travel, width: width, height: Self.panelHeight)
        orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setFrameOrigin(NSPoint(x: self.frame.minX, y: -self.frame.height - 200))
            self.alphaValue = 1
        }
    }

    // MARK: - 显隐

    func toggle() { isPresented ? hide() : show() }

    func show() {
        let showStart = CACurrentMediaTime()
        defer {
            if Perf.enabled {
                Perf.log.notice("⏱ show() 总计 \((CACurrentMediaTime() - showStart) * 1000, format: .fixed(precision: 2))ms")
            }
        }
        // 先落状态再动动画：下面移除旧动画会触发滑出的 completion，它靠这个标志判断
        // 自己是否已被作废。
        isPresented = true
        Perf.time("取前台App") { state.previousApp = NSWorkspace.shared.frontmostApplication }
        state.query = ""
        state.isSearching = false
        Perf.time("reload") { state.reload() }
        // 每次打开都重建 hosting view。两条路都堵死了才只能这样：
        //   1. 窗口 orderOut 期间 SwiftUI 会停止追踪 @Observable，隐藏时发生的数据变化
        //      不会被记录，重新显示时它并不知道自己该刷新；
        //   2. 只把 rootView 换成新实例也没用 —— ClipboardBarView 里只有一个 state 引用，
        //      新旧实例内容完全相同，SwiftUI 判定无变化直接跳过求值。
        // 症状就是面板永远显示隐藏前那一刻的快照，连相对时间都冻住。
        Perf.time("重建 hosting") {
            let hosting = NSHostingView(rootView: ClipboardBarView(state: state))
            // sizingOptions 置空是为了不让内容变化向上触发 NSView 布局，但它同时意味着
            // 这个视图**不会自己拿到尺寸** —— 必须显式给 frame 并让它跟随父视图，
            // 否则 frame 为零：layer 照常渲染，命中测试却全落空，表现为"画面正常但
            // 鼠标点不动、键盘也没反应"。
            hosting.sizingOptions = []
            hosting.frame = glassView.bounds
            hosting.autoresizingMask = [.width, .height]
            glassView.contentView = hosting
            hostingView = hosting
        }
        state.selection = 0

        guard let screen = targetScreen else { return }
        // 用 frame 而不是 visibleFrame —— 后者会主动避开 Dock 和菜单栏，面板就会浮在 Dock
        // 上方、和屏幕底边之间空出一条。原作是贴着屏幕底边的，直接盖住 Dock（面板的
        // window level 是 .statusBar，高于 Dock 的层级，盖得住）。
        let bounds = screen.frame
        // 四周留同样的边，圆角才完整、视觉才对称。注意这里必须基于 frame 而不是
        // visibleFrame —— 后者会避开 Dock，面板会被顶到 Dock 上方空出一大条。
        let width = bounds.width - Self.inset * 2
        let visible = NSRect(x: bounds.minX + Self.inset, y: bounds.minY + Self.inset,
                             width: width, height: Self.panelHeight)
        // 窗口下沿探到屏幕外，多出 travel 这么高的空间专供滑出动画使用。
        Perf.time("setFrame") {
            setFrame(NSRect(x: visible.minX, y: visible.minY - Self.travel,
                            width: width,
                            height: Self.panelHeight + Self.travel + Self.overshootRoom), display: false)
            glassView.frame = NSRect(x: 0, y: Self.travel, width: width, height: Self.panelHeight)
        }
        // 这里**不要** removeAllAnimations：位置是靠 fillMode .forwards 维持的，一移除
        // layer 就跳回原点，滑入动画等于没播。交给 slide() 读完当前位置后再精确移除。
        alphaValue = 1
        // 只在真正没上屏时才 orderFront。收起走的是"挪到屏幕外"而不是 orderOut，
        // 所以正常情况下这里是空操作 —— orderFront 要重建近全屏窗口的后备存储并让
        // Liquid Glass 重新采样背后的屏幕，实测占打开耗时的 80%。
        if !isVisible { Perf.time("orderFront") { orderFrontRegardless() } }
        Perf.time("makeKey") { makeKey() }
        state.isCommandDown = false   // 每次打开重置，避免残留上次的按键状态
        slide(to: 0, duration: Self.showDuration, bounce: Self.showBounce)
        frames.start(in: glassView)
    }

    func hide() {
        guard isPresented else { return }
        isPresented = false
        frames.stop(label: "面板显示期间")
        slide(to: -Self.travel, duration: Self.hideDuration, bounce: Self.hideBounce) { [weak self] in
            // 动画期间可能又被唤起（isPresented 变回 true），那这次收起就已作废 —— 若仍
            // 无条件收起，就会把刚显示出来的面板关掉，表现为"连点时开关失灵"。
            guard let self, !self.isPresented else { return }
            // 挪到屏幕外，而不是 orderOut。窗口保持 ordered 状态，后备存储和玻璃采样
            // 都不用重建，下次打开省掉 40ms 以上。
            self.setFrameOrigin(NSPoint(x: self.frame.minX, y: -self.frame.height - 200))
        }
    }

    /// 滑入/滑出，弹簧驱动。
    ///
    /// **不要改回 `animator().setFrame`** —— 那是逐帧改窗口几何，而这个窗口有整屏宽度、
    /// 铺着实时采样的 Liquid Glass，每帧都要重算模糊，必然掉帧。这里窗口全程不动，
    /// 只对内容层做 transform 动画，纯 GPU 合成。
    private func slide(to target: CGFloat, duration: CFTimeInterval, bounce: CGFloat,
                       completion: (() -> Void)? = nil) {
        guard let layer = glassView.layer else { completion?(); return }

        // 从当前呈现位置起步，而不是从固定端点 —— 这样动画中途被打断（滑出一半又被唤起）
        // 时是平滑接管，不会跳回起点。这是物理动画相对固定时长动画的关键好处。
        let current = layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat
        layer.removeAnimation(forKey: "slide")

        let spring = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        spring.keyPath = "transform.translation.y"
        spring.fromValue = current ?? (target == 0 ? -Self.travel : 0)
        spring.toValue = target
        // 必须显式赋 settlingDuration，否则会被 CAAnimation 默认的 0.25s 截断成半截。
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        layer.add(spring, forKey: "slide")
        CATransaction.commit()
    }

    // MARK: - 键盘

    // 方向键 / 回车 / esc 由 SearchField 截获后转发（见 ClipboardBarView.handleCommand），
    // 这样输入法能正常工作。这里只兜住搜索框未持有焦点时的情况。
    override func keyDown(with event: NSEvent) {
        // 不在搜索态时，敲下第一个可打印字符就进入搜索，并把这个字符带进去 ——
        // 焦点随后由 SearchField 依 isActive 接管，后续输入直接进输入框。
        // 注意 .function 这一条：方向键、F1–F12、Home/End 的 `characters` 落在 Unicode
        // 私有区（0xF700+），**不算控制字符**，只判断控制字符会把方向键当成正常输入 ——
        // 结果就是按方向键反而进了搜索态、往搜索框里塞了个看不见的字符，选中纹丝不动。
        if !state.isSearching,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.function),
           let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            state.isSearching = true
            state.query += typed
            return
        }
        switch Int(event.keyCode) {
        case 123: state.move(by: -1)
        case 124: state.move(by: 1)
        case 53: hide()
        case 36, 76: pasteSelected(plainText: event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    /// 按住 ⌘ 时才显示角标，松开即隐藏 —— 角标本来就只为 ⌘1…⌘9 服务。
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        state.isCommandDown = event.modifierFlags.contains(.command)
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
        // 粘贴后它就是剪贴板的当前内容，提到历史最前面
        if let id = item.id { try? ClipStore.shared.touch(id: id) }
        // 走 hide() 而不是直接 orderOut —— 后者是硬切，面板会"啪"地消失。
        // 滑出动画和粘贴是并行的：面板往下走的同时目标 App 已被激活并收到 ⌘V，
        // 观感上正好是"内容被送下去了"。resignKey 随后也会调 hide()，那次会被
        // isPresented 的 guard 挡掉，不会重复播动画。
        Paster.paste(item, to: state.previousApp, plainText: plainText, monitor: monitor) { [weak self] in
            self?.hide()
        }
    }
}
