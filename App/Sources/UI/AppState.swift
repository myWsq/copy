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
    /// 计算「几分钟前」的参考时刻，每次 reload 才更新一次。
    /// 若直接拿 `Date()` 现算，面板每重绘一次时间就跳一次，看着像在自己走。
    var referenceDate = Date()
    /// ⌘ 是否按下 —— 角标（序号）只在按住时显示，平时不占视觉。
    var isCommandDown = false
    var query: String = "" {
        didSet {
            // 直接打字就该进搜索态，不必先点图标
            if !query.isEmpty { isSearching = true }
            selection = 0        // 搜索条件变了，结果是另一批内容，回到第一条
            scheduleReload()
        }
    }
    /// 搜索条是否展开。收起时只留一个放大镜图标，把横向空间让给 Pinboard 标签。
    var isSearching = false
    var activePinboardID: Int64? { didSet { selection = 0; reload() } }
    /// 唤起面板前的前台 App —— 粘贴时要把焦点还给它。
    var previousApp: NSRunningApplication?

    /// 视图层触发的动作，由 PastePanel 注入（视图不该持有窗口引用）。
    var onPaste: ((_ plainText: Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private var cancellable: AnyDatabaseCancellable?
    private var pendingReload: Task<Void, Never>?

    init() {
        reload()
        cancellable = ClipStore.shared.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// 输入时防抖再查库。
    ///
    /// 每敲一个字符都立刻 reload 的话，一次查询加上整个卡片列表重渲染会挤在按键之间，
    /// 打字时明显掉帧。停手 120ms 再查，输入过程始终流畅，结果延迟也感觉不到。
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        // 这里**不能** cancel pendingReload —— reload 正是被那个防抖 Task 调用的，
        // 取消它等于取消自己。
        referenceDate = Date()
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
