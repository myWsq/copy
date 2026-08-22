import AppKit
import SwiftUI

/// 收藏夹名的原地编辑框。
///
/// 和 `SearchField` 一样必须是真 `NSTextField`（否则中文输入法不工作），并且要自己接管
/// 回车与 esc —— 面板对这两个键另有安排（粘贴、关闭），不拦住的话改个名字就把面板弄没了。
struct InlineNameField: NSViewRepresentable {
    let initial: String
    /// 单向汇报当前内容，供外面的隐藏 Text 撑宽度。
    ///
    /// 刻意不用 `@Binding`：双向绑定会和 `onAppear` 的初始化打架 —— 外面刚把值重置回原名，
    /// `updateNSView` 就拿它覆盖掉用户正在输入的内容，敲什么都存不下来。
    let onTextChange: (String) -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initial)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
        // 进场即取得焦点并全选，接着敲字就是覆盖旧名字
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self   // 只更新回调指向，绝不回写文本
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineNameField
        /// esc 取消后仍会触发一次 endEditing，靠它避免把取消当成提交。
        private var cancelled = false

        init(_ parent: InlineNameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancelled = true
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !cancelled, let field = notification.object as? NSTextField else { return }
            parent.onCommit(field.stringValue)   // 点别处即保存，符合 macOS 习惯
        }
    }
}
