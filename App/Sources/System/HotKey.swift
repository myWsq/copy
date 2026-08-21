import AppKit
import Carbon.HIToolbox

/// 基于 Carbon `RegisterEventHotKey` 的全局热键。
///
/// 刻意不用 `CGEventTap`：event tap 需要辅助功能权限、会拦下全系统按键、且掉线后要自己重挂。
/// Carbon 这套 API 虽被标为 legacy，却是 macOS 上唯一无需任何权限就能注册全局热键的途径，
/// Alfred / Raycast / Maccy 至今都在用。
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var handlerInstalled = false

    /// - Parameters:
    ///   - keyCode: 虚拟键码，见 `Carbon.HIToolbox` 的 `kVK_*`。
    ///   - modifiers: Carbon 修饰键掩码（`cmdKey` / `shiftKey` / `optionKey` / `controlKey`）。
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x434F5059) /* 'COPY' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            Log.system.error("RegisterEventHotKey failed: \(status)")
            Self.handlers[id] = nil
            return nil
        }
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
