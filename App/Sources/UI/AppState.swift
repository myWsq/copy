import AppKit
import GRDB
import Observation

/// 面板的可观察状态。UI 只读这里，所有写入经由 `reload()` 回到数据库。
@Observable
@MainActor
final class AppState {
    var items: [ClipItem] = []
    var pinboards: [Pinboard] = []
    var selection: Int = 0
    var query: String = "" { didSet { reload() } }
    var activePinboardID: Int64? { didSet { selection = 0; reload() } }
    /// 唤起面板前的前台 App —— 粘贴时要把焦点还给它。
    var previousApp: NSRunningApplication?

    /// 视图层触发的动作，由 PastePanel 注入（视图不该持有窗口引用）。
    var onPaste: ((_ plainText: Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private var cancellable: AnyDatabaseCancellable?

    init() {
        reload()
        cancellable = ClipStore.shared.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        do {
            items = try ClipStore.shared.recent(query: query, pinboardID: activePinboardID)
            pinboards = try ClipStore.shared.pinboards()
            selection = min(selection, max(items.count - 1, 0))
        } catch {
            Log.store.error("reload: \(error)")
        }
    }

    var selectedItem: ClipItem? { items.indices.contains(selection) ? items[selection] : nil }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    func deleteSelected() {
        guard let id = selectedItem?.id else { return }
        try? ClipStore.shared.delete(id: id)
        reload()
    }
}
