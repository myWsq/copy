import AppKit
import SwiftUI

/// 卡片的拖拽发起点。
///
/// 只负责两件事：识别拖拽手势、把卡片截成位图。**会话本身不归它管** ——
/// 拖拽会话的生命周期由系统决定，而这个视图是 SwiftUI 包出来的，卡片列表
/// 重新求值一次就可能把它丢弃。状态放在 `CardDragCoordinator`（面板持有）。
struct CardDragSource: NSViewRepresentable {
    let clipID: Int64
    /// 单击回调。这层盖在卡片上，点击也得由它转达。
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DragHandleView()
        view.clipID = clipID
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragHandleView else { return }
        view.clipID = clipID
        view.onClick = onClick
    }
}

private final class DragHandleView: NSView {
    var clipID: Int64 = -1
    var onClick: (() -> Void)?

    private var mouseDownPoint: NSPoint = .zero
    private var didDrag = false
    /// 按下那一刻就截好的卡片位图。见 `mouseDown` 的注释。
    private var pendingSnapshot: NSImage?

    /// 只认领左键。右键留给 SwiftUI 的 contextMenu，悬停留给卡片自己的高亮。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
        // 按下就截，不等越过拖拽阈值。截一张卡片要 20~40ms，等到那时再截，
        // 这段时间全落在"手已经动了、预览还没出来"的空档里，手感就是拖一段才生效。
        // 放在按下到松开之间则完全被人手的动作时间盖住 —— 单击的反馈在 mouseUp，
        // 不受影响。代价是纯点击也会白截一张，用户感知不到。
        pendingSnapshot = Perf.time("拖拽截图", { snapshot() })
    }

    /// 第一次移动就开始拖，**不设距离阈值**。
    ///
    /// 阈值原本是用来分开"点击的抖动"和"真的要拖"——人按下时必然有几个像素的位移，
    /// 没有阈值的话点击会被判成拖拽而失效。但那等于拿一段死区去换点击的可靠性，
    /// 手感上就是"要拖一下才生效"。改成把判定推迟到松手那一刻（见 `endedAt`）：
    /// 没走远又没落在收藏夹上，就仍然算点击。于是两样都不用让。
    override func mouseDragged(with event: NSEvent) {
        guard !didDrag,
              let coordinator = (window as? PastePanel)?.dragCoordinator,
              let image = pendingSnapshot,
              let window else { return }
        didDrag = true
        pendingSnapshot = nil       // 交给 coordinator 了
        coordinator.begin(clipID: clipID, image: image, from: self, event: event,
                          anchor: window.convertPoint(toScreen: mouseDownPoint),
                          onTap: onClick ?? {})
    }

    override func mouseUp(with event: NSEvent) {
        pendingSnapshot = nil
        guard !didDrag else { return }
        onClick?()      // 按下又松开、没移动 = 单击
    }

    /// 把卡片当前的样子截成位图。
    ///
    /// 截 SwiftUI 的宿主视图，**不是** `window.contentView` —— 后者底下是
    /// `NSGlassEffectView`，`cacheDisplay` 会连玻璃一起重新采样，实测 44ms vs 22ms。
    /// 也不能截自己：这层是透明的，截出来只有空白。
    private func snapshot() -> NSImage? {
        guard let host = hostingAncestor else { return nil }
        let rect = convert(bounds, to: host)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        host.cacheDisplay(in: rect, to: rep)
        let raw = NSImage(size: bounds.size)
        raw.addRepresentation(rep)
        return rounded(raw)
    }

    private var hostingAncestor: NSView? {
        var view: NSView? = self
        while let current = view {
            if NSStringFromClass(type(of: current)).contains("HostingView") { return current }
            view = current.superview
        }
        return nil
    }

    /// 按卡片的圆角裁掉四角。卡片是圆角的而截图是矩形，四角截到的是背后的
    /// 面板玻璃底，不裁掉就是一圈黑边。
    private func rounded(_ image: NSImage) -> NSImage {
        let size = image.size
        let scale = window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect,
                     xRadius: ClipCard.radius, yRadius: ClipCard.radius).setClip()
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: size)
        output.addRepresentation(rep)
        return output
    }
}

/// 一次卡片拖拽的全部状态，由 `PastePanel` 持有。
///
/// **预览是自绘的，不用 NSDraggingSession 的拖拽图像。** 本机实测（最小复现程序逐项排除）：
/// 这一代 macOS 会把会话图像在开场动画里压进 128×128 的标准盒子，公开 API
/// （`draggingFormation`、`enumerateDraggingItems` 重设 `draggingFrame`）和私有开关
/// （`animatesToDraggingFormationOnBeginDrag`）都拿不回原尺寸 —— 之前"缩略图自己变小、
/// 怎么改都改不好"的根源就在这。原作 Paste 也是这么做的：拖拽期间它会挂出一个全屏、
/// layer 500（正是 kCGDraggingWindowLevel）的透明窗口，卡片预览画在里面自己动。
///
/// 于是分工是：**会话只管数据与落点**（pasteboard、标签的 onDrop、松手语义、加号光标），
/// item 不带任何图像；**预览窗口只管好看**（原尺寸跟手、出栏缩小、弹簧动画），两边互不干涉。
/// 这也顺带把掉帧治了 —— 系统不再为会话图像走 CPU 重绘路径，预览只是一层普通 CALayer，
/// 每个鼠标事件改一次 position，纯 GPU 合成。
@MainActor
final class CardDragCoordinator: NSObject, NSDraggingSource {
    /// 会话期间把正在拖的 clipID 登记到这里，收藏夹标签的 DropDelegate 直接读。
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    /// 离开卡片行后缩到多小。让开视野，好看清要放进哪个收藏夹。
    private static let shrunkScale: CGFloat = 0.45
    /// 预览半透明，透出底下的卡片 —— 系统拖拽图像和原作都是这个观感。
    private static let previewOpacity: Float = 0.8
    private static let springDuration: CFTimeInterval = 0.32
    private static let springBounce: CGFloat = 0.24   // 缩放带一点回弹，"弹簧感"
    /// 松手无目标时飞回原位的时长。临界阻尼，不回弹 —— 干脆归位。
    private static let returnDuration: CFTimeInterval = 0.28

    /// 全屏透明预览窗口，惰性建一次后复用（省掉每次拖拽的窗口创建开销）。
    private var overlay: NSWindow?
    private var previewLayer: CALayer?
    /// 卡片按下时的屏幕位置，飞回动画的终点；上下边界就是"卡片这一栏"的判定带。
    private var cardFrame: NSRect = .zero
    /// 抓点在卡片内的位置（未翻转坐标）。预览以它为锚，缩放时抓住的点不动。
    private var grab: NSPoint = .zero
    private var shrunk = false
    /// 鼠标按下时的屏幕位置，用来在松手时判断"这到底是一次点击还是一次拖拽"。
    private var anchor: NSPoint = .zero
    private var onTap: (() -> Void)?
    /// 松手时位移小于它，且没落在任何收藏夹上，就还原成一次点击。
    private static let tapSlop: CGFloat = 4

    func begin(clipID: Int64, image: NSImage, from view: NSView, event: NSEvent,
               anchor: NSPoint, onTap: @escaping () -> Void) {
        self.anchor = anchor
        self.onTap = onTap
        guard let window = view.window,
              let screen = window.screen ?? NSScreen.screens.first else { return }

        cardFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        grab = view.convert(event.locationInWindow, from: nil)
        shrunk = false

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(clipID), forType: .string)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // 只给 frame 不给 contents —— 会话没有图像，系统就什么都不画，
        // 预览完全由下面的 overlay 承担。
        item.draggingFrame = view.bounds

        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        // 取消时的"滑回"由我们自己的图层动画做，系统没图可滑。
        session.animatesToStartingPositionsOnCancelOrFail = false
        state.draggingClipID = clipID

        showPreview(image: image, on: screen)
    }

    // MARK: - 预览图层

    private func showPreview(image: NSImage, on screen: NSScreen) {
        let window = overlay ?? makeOverlay()
        overlay = window
        window.setFrame(screen.frame, display: false)

        previewLayer?.removeFromSuperlayer()
        let layer = CALayer()
        layer.contents = image
        layer.opacity = Self.previewOpacity
        layer.bounds = CGRect(origin: .zero, size: cardFrame.size)
        layer.contentsScale = screen.backingScaleFactor
        // 锚点设在抓点上：位置跟随光标、缩放围绕光标，都不用再做补偿。
        layer.anchorPoint = CGPoint(x: grab.x / cardFrame.width, y: grab.y / cardFrame.height)
        layer.position = convertToOverlay(NSPoint(x: cardFrame.minX + grab.x,
                                                  y: cardFrame.minY + grab.y))
        window.contentView?.layer?.addSublayer(layer)
        previewLayer = layer
        window.orderFrontRegardless()
    }

    private func makeOverlay() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true   // 纯展示层，落点判定必须穿透它到面板
        // 系统拖拽窗口的层级（500），Paste 的预览窗口同样在这一层。
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.animationBehavior = .none
        window.contentView?.wantsLayer = true
        return window
    }

    /// 屏幕坐标 → overlay 图层坐标（窗口盖满屏幕，只差一个原点平移）。
    private func convertToOverlay(_ p: NSPoint) -> CGPoint {
        guard let frame = overlay?.frame else { return p }
        return CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
    }

    private func setScale(_ scale: CGFloat) {
        guard let layer = previewLayer else { return }
        let current = (layer.presentation() ?? layer)
            .value(forKeyPath: "transform.scale.x") as? CGFloat ?? 1
        layer.removeAnimation(forKey: "scale")

        let spring = CASpringAnimation(perceptualDuration: Self.springDuration,
                                       bounce: Self.springBounce)
        spring.keyPath = "transform.scale"
        spring.fromValue = current
        spring.toValue = scale
        spring.duration = spring.settlingDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(scale, forKeyPath: "transform.scale")   // 模型值落定，动画只管过渡
        layer.add(spring, forKey: "scale")
        CATransaction.commit()
    }

    private func tearDownPreview() {
        Perf.time("预览收场") {
            previewLayer?.removeFromSuperlayer()
            previewLayer = nil
            // 不 orderOut —— 拆掉近全屏窗口的后备存储要 17–19ms，正好压在松手那一拍上，
            // 是拖放收尾仅剩的一下顿挫。与面板 hide() 同一策略：挪到屏幕外保持 ordered，
            // 下次拖拽 showPreview 的 setFrame 会把它带回来。
            overlay?.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication: .copy   // 光标带加号：内容不从历史消失，只是多个归属
        // 卡片拖出 App 暂不支持 —— pasteboard 里只有内部 id，让外部落点全部拒收，
        // 免得往别人文档里粘一个"42"。
        case .outsideApplication: []
        @unknown default: []
        }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let layer = previewLayer else { return }
        // 位置逐事件硬跟，不做动画 —— 跟手的意思就是零延迟。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = convertToOverlay(screenPoint)
        CATransaction.commit()

        // 只看垂直方向 —— "卡片这一栏"是一条横贯面板的水平带，进出它只有上下之分。
        // 横向经过别的卡片仍在栏内，不缩放（Paste 亦然）。screenPoint 就是光标位置
        // （与 session.draggingLocation、NSEvent.mouseLocation 逐帧比对过，三者一致）。
        let shouldShrink = screenPoint.y < cardFrame.minY || screenPoint.y > cardFrame.maxY
        guard shouldShrink != shrunk else { return }
        shrunk = shouldShrink
        setScale(shouldShrink ? Self.shrunkScale : 1)
    }

    /// 落点接住了（performDrop）就立刻收预览，**不等 endedAt** —— 系统要走完自己的
    /// 拖放收尾才调源端的 endedAt，实测比 performDrop 晚约 320ms；而 assign 引发的
    /// 重渲染下一帧就上屏。预览留到 endedAt 才拆，看起来就是"卡片顶栏已变色、
    /// 缩略图还悬着"卡一下。由 AppState.dropAssign 在落库**之前**调用。
    func dropConcluded() {
        onTap = nil
        tearDownPreview()
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // performDrop 在 endedAt 之前到达（实测顺序固定），这里清掉不影响落点读取。
        state.draggingClipID = nil

        if Perf.enabled { Perf.log.notice("⏱ 拖拽会话结束 operation=\(operation.rawValue)") }
        Perf.stallProbe("拖拽会话结束")
        // 成功落点的预览已在 dropConcluded 收掉，这里只剩"没落上"的两种收尾。
        guard let layer = previewLayer else { return }
        let tap = onTap
        onTap = nil

        // 没走远、也没落进收藏夹 —— 那就是一次点击，只是手抖了几个像素。
        // 预览直接收掉，不做飞回动画：它压根没离开过原位。
        let travelled = hypot(screenPoint.x - anchor.x, screenPoint.y - anchor.y)
        if operation.isEmpty, travelled < Self.tapSlop {
            tearDownPreview()
            tap?()
            return
        }

        if operation.isEmpty {
            // 没落在任何收藏夹上：飞回原位再收场，跟系统的取消动画同一语义。
            let home = convertToOverlay(NSPoint(x: cardFrame.minX + grab.x,
                                                y: cardFrame.minY + grab.y))
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.returnDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { self.tearDownPreview() } }
            layer.removeAnimation(forKey: "scale")
            layer.position = home
            layer.setValue(1 as CGFloat, forKeyPath: "transform.scale")
            CATransaction.commit()
        } else {
            // 正常成功路径不会走到这（dropConcluded 已收）；兜底给未知的成功收尾。
            tearDownPreview()
        }
    }
}
