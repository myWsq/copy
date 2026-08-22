import AppKit
import SwiftUI

/// 收藏夹标签的右键菜单。
///
/// 这里绕开了 SwiftUI 的 `.contextMenu`，自己拼 `NSMenu` —— 原作那种"一行彩色圆点"
/// 是 `NSMenuItem` 的自定义 view，SwiftUI 的菜单只接受菜单项，做不出来。
struct PinboardContextMenu: NSViewRepresentable {
    let colorIndex: Int
    let onRename: () -> Void
    let onDelete: () -> Void
    let onPickColor: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RightClickView()
        view.owner = self
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RightClickView)?.owner = self
    }
}

/// 盖在标签上、只负责接右键的透明视图。
///
/// 必须盖在**上层**（overlay）：放在 background 里的话右键会先被上层的 Button 吃掉。
/// 但盖在上层又会挡住左键，所以重写 hitTest —— 只有右键（含 Control-左键）才认领事件，
/// 其余一律返回 nil 放行给下面的按钮，点击和悬停都不受影响。
private final class RightClickView: NSView {
    var owner: PinboardContextMenu?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return super.hitTest(point)
        case .leftMouseDown, .leftMouseUp where event.modifierFlags.contains(.control):
            return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let owner else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let rename = NSMenuItem(title: Localized.rename, action: #selector(fireRename), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        let delete = NSMenuItem(title: Localized.deleteBoard, action: #selector(fireDelete), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)

        menu.addItem(.separator())

        let swatches = NSMenuItem()
        let row = ColorSwatchRow(selected: owner.colorIndex) { [weak self] index in
            self?.owner?.onPickColor(index)
        }
        row.frame = NSRect(origin: .zero, size: row.intrinsicContentSize)
        swatches.view = row
        menu.addItem(swatches)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func fireRename() { owner?.onRename() }
    @objc private func fireDelete() { owner?.onDelete() }
}

/// 菜单里那一行可点的彩色圆点。
private final class ColorSwatchRow: NSView {
    private let selected: Int
    private let onPick: (Int) -> Void
    private var hovered: Int?
    // 尺寸按原作截图量的：圆点比第一版小不少，挨得也更紧
    private let dot: CGFloat = 14
    private let gap: CGFloat = 8
    private let inset: CGFloat = 14

    init(selected: Int, onPick: @escaping (Int) -> Void) {
        self.selected = selected
        self.onPick = onPick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var swatches: [NSColor] { PinboardPalette.nsColors }

    override var intrinsicContentSize: NSSize {
        NSSize(width: inset * 2 + CGFloat(swatches.count) * dot + CGFloat(swatches.count - 1) * gap,
               height: dot + 18)
    }

    private func rect(at index: Int) -> NSRect {
        NSRect(x: inset + CGFloat(index) * (dot + gap),
               y: (bounds.height - dot) / 2, width: dot, height: dot)
    }

    /// 菜单运行在 event tracking 模式下，tracking area 要用 `.activeAlways` 才收得到鼠标移动。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self))
    }

    private func index(at point: NSPoint) -> Int? {
        swatches.indices.first { rect(at: $0).insetBy(dx: -gap / 2, dy: -6).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let next = index(at: convert(event.locationInWindow, from: nil))
        guard next != hovered else { return }
        hovered = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in swatches.enumerated() {
            let box = rect(at: index)
            // 悬停时垫一层浅色圆底，比放大圆点更稳 —— 尺寸不变，一行不会跟着抖
            if index == hovered {
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(ovalIn: box.insetBy(dx: -5, dy: -5)).fill()
            }
            color.setFill()
            NSBezierPath(ovalIn: box).fill()
            guard index == selected else { continue }
            // 选中的那个套一圈细环，而不是画对勾 —— 对勾压在饱和色上很难看清
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: -3, dy: -3))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick(index)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
