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
    /// 是否处于搜索态。焦点完全由它驱动：为真时抢占 first responder，为假时交还给面板。
    let isActive: Bool
    /// 返回 true 表示该命令已被消费，不再交给文本框。
    let onCommand: (Selector) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = Localized.search
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self

        // 焦点跟着 isActive 走。交还焦点时置为 nil，让面板自己接管键盘 —— 面板会在
        // 收到可打印字符时重新把 isActive 打开，所以"直接打字即搜索"依然成立。
        guard let window = field.window else { return }
        let editing = window.firstResponder === field.currentEditor()
        if isActive, !editing {
            window.makeFirstResponder(field)
        } else if !isActive, editing {
            window.makeFirstResponder(nil)
        }
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
