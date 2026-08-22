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
    /// 计算「几分钟前」的参考时刻，只在面板打开时刷新一次（由 PastePanel.show 负责）。
    /// 若直接拿 `Date()` 现算，面板每重绘一次时间就跳一次，看着像在自己走。
    /// 也**不要**改回每次 reload 都重置：所有卡片的 `now` 一起变，等于把整行 60 张全部
    /// 作废重渲染，归类/删除这种只动一条的操作也要付全量渲染的代价 —— 实测这正是
    /// 拖拽归类松手瞬间卡顿的主因。
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
    /// 搜索条是否展开。收起时只留一个放大镜图标，把横向空间让给收藏夹标签。
    var isSearching = false
    /// 正在原地改名的收藏夹。与搜索态互斥 —— 两个输入框不能同时抢焦点。
    var renamingPinboardID: Int64?
    /// 刚新建、还没确认过名字的那个。按 esc 取消即连同新建一起撤销，
    /// 免得手一抖攒下一堆空的「未命名」。
    private var pendingNewPinboardID: Int64?
    var activePinboardID: Int64? { didSet { selection = 0; reload() } }
    /// 唤起面板前的前台 App —— 粘贴时要把焦点还给它。
    var previousApp: NSRunningApplication?
    /// 正在被拖拽的卡片 id，由 CardDragCoordinator 在会话期间维护。
    /// 收藏夹标签的 DropDelegate 直接读它拿落点数据 —— 拖拽是纯内部的（会话对外部落点
    /// 全部拒收），id 就在自己手里，不必绕 NSItemProvider 的异步 XPC 往返（实测每次
    /// 10–25ms，还会把外部拖进来的任意数字文本误当成卡片 id）。没有视图在 body 里读它，
    /// 写入不会触发重渲染。
    var draggingClipID: Int64?

    /// 拖拽预览的协调器，由 PastePanel 注入。落点侧要在落库前先收预览（见 dropAssign），
    /// 只有它能收。@ObservationIgnored：纯接线，不参与渲染依赖。
    @ObservationIgnored weak var dragCoordinator: CardDragCoordinator?

    /// 视图层触发的动作，由 PastePanel 注入（视图不该持有窗口引用）。
    var onPaste: ((_ plainText: Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private var cancellable: AnyDatabaseCancellable?
    private var pendingReload: Task<Void, Never>?

    init() {
        reload()
        cancellable = ClipStore.shared.observeChanges { [weak self] in
            MainActor.assumeIsolated {
                if Perf.enabled { Perf.log.notice("⏱ observation 触发 reload") }
                Perf.stallProbe("observation reload")
                self?.reload()
            }
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
        do {
            items = try ClipStore.shared.recent(query: query, pinboardID: activePinboardID)
            pinboards = try ClipStore.shared.pinboards()
            selection = min(selection, max(items.count - 1, 0))
            // 面板开着期间捕获到新内容时，参考时刻要跟上到最新一条 —— 否则新卡片的
            // createdAt 晚于参考时刻，相对时间会算出未来时态。只单调前移，别的 reload
            // （归类、删除、改色）不动它，未变化的卡片才能被 SwiftUI 判等跳过。
            if let newest = items.first?.createdAt, newest > referenceDate {
                referenceDate = newest
            }
        } catch {
            Log.store.error("reload: \(error)")
        }
    }

    var selectedItem: ClipItem? { items.indices.contains(selection) ? items[selection] : nil }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    // MARK: - Pinboards

    /// 新建后**不切过去**，只进入改名态。新板必然是空的，切过去只会把当前看的内容
    /// 换成一个空列表，白白打断。
    func createPinboard() {
        let name = Localized.newPinboardName(pinboards.count + 1)
        // 自动挑一个还没被占用的颜色：建头几个时天然就是红、橙、黄……，省掉手动改色。
        // 颜色用尽后按数量取模循环，不至于卡住。
        let used = Set(pinboards.map(\.colorIndex))
        let color = (0..<PinboardPalette.colors.count).first { !used.contains($0) }
            ?? (pinboards.count % PinboardPalette.colors.count)
        do {
            let board = try ClipStore.shared.createPinboard(name: name, colorIndex: color)
            reload()
            isSearching = false
            renamingPinboardID = board.id   // 建完直接进改名，省一步右键
            pendingNewPinboardID = board.id
        } catch {
            Log.store.error("createPinboard: \(error)")
        }
    }

    /// 新建一个收藏夹并把这条内容放进去，随即进入改名。
    ///
    /// 省掉"先去工具栏建板、再回来右键归类"两步 —— 想收藏某条内容时，往往正是这一刻
    /// 才意识到需要一个新分类。
    func createPinboard(containing item: ClipItem) {
        let name = Localized.newPinboardName(pinboards.count + 1)
        let used = Set(pinboards.map(\.colorIndex))
        let color = (0..<PinboardPalette.colors.count).first { !used.contains($0) }
            ?? (pinboards.count % PinboardPalette.colors.count)
        do {
            let board = try ClipStore.shared.createPinboard(name: name, colorIndex: color)
            if let clipID = item.id, let boardID = board.id {
                try ClipStore.shared.assign(clip: clipID, to: boardID)
            }
            reload()
            isSearching = false
            renamingPinboardID = board.id
            pendingNewPinboardID = board.id
        } catch {
            Log.store.error("createPinboard(containing:): \(error)")
        }
    }

    func rename(_ board: Pinboard, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingPinboardID = nil
        pendingNewPinboardID = nil
        guard let id = board.id, !trimmed.isEmpty else { return }
        try? ClipStore.shared.renamePinboard(id: id, to: trimmed)
        reload()
    }

    /// 取消改名。若取消的正是刚新建的那个，连这次新建一起撤销。
    func cancelRename() {
        if let id = renamingPinboardID, id == pendingNewPinboardID {
            try? ClipStore.shared.deletePinboard(id: id)
            if activePinboardID == id { activePinboardID = nil } else { reload() }
        }
        renamingPinboardID = nil
        pendingNewPinboardID = nil
    }

    func setColor(_ board: Pinboard, to index: Int) {
        guard let id = board.id else { return }
        try? ClipStore.shared.setPinboardColor(id: id, to: index)
        reload()
    }

    func delete(_ board: Pinboard) {
        guard let id = board.id else { return }
        try? ClipStore.shared.deletePinboard(id: id)
        if activePinboardID == id { activePinboardID = nil } else { reload() }
    }

    /// 把某条记录归入某个板；传 nil 表示移出。
    /// 按条目而不是按"当前选中"操作 —— 右键点的那张未必就是选中的那张。
    func assign(_ item: ClipItem, to pinboardID: Int64?) {
        guard let clipID = item.id else { return }
        assign(clipID: clipID, to: pinboardID)
    }

    /// 收藏夹标签接住落点（performDrop）时走这里而不是直接 assign：**先收预览，再落库**。
    /// 收预览不能等源端的 endedAt —— 系统要走完自己的拖放收尾才调它（实测晚 ~320ms），
    /// 而 assign 引发的顶栏变色下一帧就上屏，缩略图会悬到 endedAt 才消失，就是那个"卡一下"。
    func dropAssign(clipID: Int64, to pinboardID: Int64?) {
        dragCoordinator?.dropConcluded()
        assign(clipID: clipID, to: pinboardID)
    }

    /// 拖拽用：跨视图只传得动标识，传不动整条记录。
    func assign(clipID: Int64, to pinboardID: Int64?) {
        Perf.time("assign 写库") { try? ClipStore.shared.assign(clip: clipID, to: pinboardID) }
        Perf.time("assign reload") { reload() }
        Perf.stallProbe("assign")
    }

    /// ⌘← / ⌘→ 在「全部」和各个板之间循环。
    func cyclePinboard(by delta: Int) {
        guard !pinboards.isEmpty else { return }
        let ids: [Int64?] = [nil] + pinboards.map(\.id)
        let current = ids.firstIndex { $0 == activePinboardID } ?? 0
        let next = (current + delta + ids.count) % ids.count
        activePinboardID = ids[next]
    }

    func deleteSelected() {
        guard let id = selectedItem?.id else { return }
        Perf.time("delete 写库") { try? ClipStore.shared.delete(id: id) }
        Perf.time("delete reload") { reload() }
        Perf.stallProbe("delete")
    }
}
