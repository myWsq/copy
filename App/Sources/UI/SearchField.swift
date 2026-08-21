import AppKit
import SwiftUI

/// 搜索输入框。
///
/// 不用 SwiftUI 的 `TextField`，因为需要同时满足两个互相打架的要求：
///   1. 必须是真正的 `NSTextField` —— 中文/日文输入法要靠它才能正常工作；
///   2. 方向键、回车、esc 必须留给卡片导航，而 `NSTextField` 默认会吞掉它们去移动光标。
///
/// AppKit 的解法是 `control(_:textView:doCommandBy:)`：在文本控件处理按键**之前**截获它，
/// 返回 true 表示「我处理了，你别管」。这是原生做键盘协调的标准姿势，SwiftUI 没有等价物。
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    /// 返回 true 表示该命令已被消费，不再交给文本框。
    let onCommand: (Selector) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = AutoFocusTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Search"
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            parent.onCommand(selector)
        }
    }
}

/// 一进入窗口就抢焦点 —— 面板一弹出即可直接打字，无需先点击搜索框。
private final class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}
