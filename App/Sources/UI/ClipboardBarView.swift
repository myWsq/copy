import AppKit
import SwiftUI

/// 底部剪贴板条。几何取自对 Paste 6.6.8 截图的像素测量（见 CLAUDE.md「参考原作」）。
struct ClipboardBarView: View {
    @Bindable var state: AppState
    /// 只为强制 SwiftUI 重新求值而存在。
    ///
    /// 窗口隐藏期间 SwiftUI 会停止追踪 @Observable，重新显示时并不知道该刷新；而只把
    /// rootView 换成新实例也没用 —— 结构体里只有一个 state 引用，新旧完全相同，会被判定
    /// 无变化直接跳过。给它一个每次递增的值，值真的变了才会重新求值。
    var revision: Int = 0

    /// 展开后搜索条的最大宽度。
    private static let searchWidth: CGFloat = 520
    /// 展开**不做动画**，别加回去。
    ///
    /// 这是一次布局动画：宽度变化牵动整行重排，链条上还挂着一个 NSViewRepresentable，
    /// 每一帧都要重算 SwiftUI 布局并让 AppKit 跟着走，同时面板底下还是实时采样的玻璃。
    /// 实测（反复展开收起 12 次）：0.30s 弹簧掉 25 帧 / 最差 105ms，0.16s 缓出 31 帧 / 110ms，
    /// 不做动画 18 帧 / 71ms。缩短时长没用 —— 成本不在时长，在每帧的布局重算。
    /// 展开动画。这是布局动画，每帧都要重算 SwiftUI 布局并驱动 AppKit 跟随，
    /// 实测比不做动画多掉约 7 帧 —— 这是为手感付的已知代价，不是 bug。
    static let searchAnimation: Animation? = .spring(duration: 0.30, bounce: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            cards
        }
        // 点面板空白处退出搜索。**必须挂在 background 上**，不能直接给整个 VStack 加
        // contentShape + onTapGesture —— 那会把命中区域扩成一整块，连卡片的点击一起吃掉，
        // 表现为"搜索之后鼠标点不动了"。放进背景层，卡片天然在它上面，优先接管点击。
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(Self.searchAnimation) { state.isSearching = false } }
        )
    }

    /// 把导航类按键从搜索框里截出来交给卡片列表；其余（含输入法组字）留给文本框。
    private func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveUp(_:)):
            state.move(by: -1)
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveDown(_:)):
            state.move(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            state.onPaste?(false)
        case #selector(NSResponder.insertLineBreak(_:)):            // ⇧↩
            state.onPaste?(true)
        case #selector(NSResponder.cancelOperation(_:)):            // esc
            // 搜索中先退出搜索，再按一次才关面板 —— 免得输错一个字就把整个面板弄没了
            if state.isSearching {
                state.query = ""
                withAnimation(Self.searchAnimation) { state.isSearching = false }
            } else {
                state.onDismiss?()
            }
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):    // ⌘⌫
            state.deleteSelected()
        case #selector(NSResponder.moveToBeginningOfLine(_:)):      // ⌘←
            state.cyclePinboard(by: -1)
        case #selector(NSResponder.moveToEndOfLine(_:)):            // ⌘→
            state.cyclePinboard(by: 1)
        default:
            return false    // 其余按键归文本框，退格才能正常删字
        }
        return true
    }

    // MARK: - 工具栏

    /// 收起时只有一个放大镜图标、标签组居中；展开后搜索条铺满，标签退到右侧。
    ///
    /// `SearchField` 始终留在视图树里，只用宽度和透明度控制显隐 —— 用 `if` 把它换进换出
    /// 会重建 NSTextField，焦点随之丢失，就没法"直接打字即搜索"了。
    /// 空状态：一行大字，不加图标 —— 与原作一致。三种情况分开写，笼统一句"没有内容"
    /// 会让人分不清是搜没搜到、还是这个收藏夹本来就空。
    private var emptyState: some View {
        let text: String = {
            if !state.query.isEmpty { return Localized.emptySearch }
            if state.activePinboardID != nil { return Localized.emptyBoard }
            return Localized.emptyHistory
        }()
        return Text(text)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.white.opacity(0.22))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            // 间距要跟着搜索态走：收起时里面藏着 1pt 的输入框和 0pt 的筛选图标，
            // HStack 仍会为它们插入间距，白白多出十几 pt，看着就是"图标离标签太远"。
            HStack(spacing: state.isSearching ? 7 : 0) {
                // 尺寸固定 28 不随展开变化 —— 之前展开时缩到 20，位置又同时左移，
                // 点击触发时就会看到它"闪"过去。现在只有位置随容器平移，是连续的。
                // action 里必须显式 withAnimation：SwiftUI 的 Button 在一个禁用隐式动画的
                // 事务里执行 action，外层的 .animation(value:) 对它不生效 —— 表现就是
                // 键盘触发有平移动画、点按钮却是硬切。
                ToolbarIconButton(symbol: "magnifyingglass",
                                  isActive: state.isSearching,
                                  showsChrome: !state.isSearching) {
                    withAnimation(Self.searchAnimation) { state.isSearching = true }
                }

                // 改名时把焦点让出去，两个 NSTextField 不能同时抢 first responder
                SearchField(text: $state.query,
                            isActive: state.isSearching && state.renamingPinboardID == nil,
                            onCommand: handleCommand)
                    // 高度必须锁：NSTextField 的固有高度比文字大不少，会把整条搜索条顶厚。
                    .frame(maxWidth: state.isSearching ? .infinity : 1, maxHeight: 17)
                    .opacity(state.isSearching ? 1 : 0)

            }
            // 锁死高度，别让内部的图标按钮（28pt）加上下 padding 把整条顶到 42pt ——
            // 那比旁边的标签高出一半。固定高度同时也让展开动画只剩宽度在变。
            .padding(.horizontal, state.isSearching ? 12 : 0)
            .frame(height: 30)
            // 试过「固定 SearchField 宽度 + 外层 .clipped()」想省掉 AppKit 每帧重排，
            // 结果掉帧从 25 涨到 47 —— clipped 会引入离屏渲染，比重排还贵。别再试了。
            .frame(maxWidth: state.isSearching ? Self.searchWidth : nil)
            .background {
                Capsule()
                    .fill(.black.opacity(state.isSearching ? 0.22 : 0))
                    .overlay(
                        Capsule().strokeBorder(Color.systemAccent.opacity(state.isSearching ? 1 : 0),
                                               lineWidth: 2)
                    )
            }

            // 搜索展开时标签只留图标/圆点，把横向空间让给搜索条 —— 与原作一致。
            PinboardTab(title: Localized.clipboard, symbol: "clock.arrow.circlepath", tint: nil,
                        showsTitle: !state.isSearching,
                        isActive: state.activePinboardID == nil,
                        draggedClip: { state.draggingClipID },
                        onDropClip: { state.dropAssign(clipID: $0, to: nil) }) {   // 拖回这里 = 移出收藏夹
                state.activePinboardID = nil
            }
            ForEach(state.pinboards) { board in
                PinboardTab(title: board.name, symbol: "circle.fill",
                            tint: PinboardPalette.color(board.colorIndex),
                            showsTitle: !state.isSearching,
                            isActive: state.activePinboardID == board.id,
                            renaming: state.renamingPinboardID == board.id,
                            onCommitName: { state.rename(board, to: $0) },
                            onCancelName: { state.cancelRename() },
                            draggedClip: { state.draggingClipID },
                            onDropClip: { state.dropAssign(clipID: $0, to: board.id) },
                            action: { state.activePinboardID = board.id })
                    // 双击原地改名，用 simultaneousGesture 而**不是** `.onTapGesture(count: 2)`。
                    //
                    // 只要视图上存在双击手势，SwiftUI 就会让单击先等满一个双击判定窗口
                    // （系统的双击间隔，两三百毫秒）才敢响应 —— 那不是掉帧，是明明白白的
                    // 等待，切换收藏夹会明显"不跟手"。simultaneousGesture 与 Button 并行，
                    // 单击零延迟，双击再额外触发改名。代价是双击会先切换一次到该收藏夹，
                    // 但那正是双击的目标，无所谓。
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        state.isSearching = false
                        state.renamingPinboardID = board.id
                    })
                    // 右键菜单盖在标签上层，见 PinboardMenu.swift —— 要的是原作那种一行圆点，
                    // SwiftUI 的 .contextMenu 放不进自定义视图。它只认领右键，左键穿透。
                    .overlay(
                        PinboardContextMenu(
                            colorIndex: board.colorIndex,
                            onRename: {
                                state.isSearching = false
                                state.renamingPinboardID = board.id
                            },
                            onDelete: { state.delete(board) },
                            onPickColor: { state.setColor(board, to: $0) }
                        )
                    )
            }
            // 搜索时收起「+」：这时是在找东西，不是在整理，新建入口只会占地方
            ToolbarIconButton(symbol: "plus", isActive: false, showsChrome: true) {
                withAnimation(Self.searchAnimation) { state.createPinboard() }
            }
            .help(Localized.newBoard)
            .frame(width: state.isSearching ? 0 : 28)
            .opacity(state.isSearching ? 0 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .animation(Self.searchAnimation, value: state.isSearching)   // 见 searchAnimation 的说明
    }

    // MARK: - 卡片流

    private var cards: some View {
        // 这三个值必须在 body 里先读出来。
        //
        // 它们如果只在 ForEach 的闭包内部被访问，SwiftUI 就建立不了依赖 —— ForEach 配
        // LazyHStack 的闭包是**惰性执行**的，body 求值那一刻根本没碰到这些属性。
        // 症状很迷惑：items 变化能刷新（它在 body 里被直接读到），selection 变化却不刷新，
        // 表现为按方向键日志里选中项在动、界面上高亮框却纹丝不动甚至消失。
        let selection = state.selection
        let now = state.referenceDate
        let showsIndex = state.isCommandDown
        // 收藏夹 id → 调色板下标。归入收藏夹的卡片顶栏换成收藏夹的颜色（对标 Paste，
        // 在「剪贴板」总览里同样生效），未归类的维持来源 App 主色。
        let boardColors: [Int64: Int] = Dictionary(uniqueKeysWithValues:
            state.pinboards.compactMap { board in board.id.map { ($0, board.colorIndex) } })

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // **用 HStack，不要用 LazyHStack。**
                //
                // LazyHStack 在数据源大幅缩水时（搜索把 58 条过滤成 14 条）会算错可见范围，
                // 之后只肯创建第一张卡片，其余视图压根不存在 —— 表现为选中框看不见、鼠标
                // 点不到，而日志里 selection、items 一切正常，极难想到是渲染层的问题。
                // 试过给它加 .id() 强制重建，无效。
                // **用 HStack，不要用 LazyHStack。**（2026-08-22 二次确认，别再试第三回）
                //
                // LazyHStack 在数据源大幅缩水时（搜索把 100 条过滤成 30 条）会算错可见范围，
                // 之后只肯创建第一张卡片 —— 选中框看不见、鼠标点不到，而日志里 selection、
                // items 一切正常。第一次以为是并存的 @Observable 依赖 bug 所致，修好后重试，
                // 症状照旧。给它加 .id() 强制重建也无效。
                //
                // 代价是所有条目都真的渲染，所以 ClipStore.pageSize 压得比较小。
                HStack(spacing: ClipCard.gap) {
                    // identity 用 fingerprint。试过换成位置（想让视图原地复用、免去销毁重建），
                    // 实测反而更慢 —— 内容全变时逐属性 diff 的代价高于直接重建。
                    //
                    // 仍要用 `Array(enumerated())` 在 ForEach **外**读一次 items：改成
                    // `ForEach(state.items.indices)` 再在闭包里取 `state.items[index]`，
                    // 会让每张卡片各自建立一条对 items 的依赖，上百个依赖节点能把
                    // AttributeGraph 压垮（实测 UI 开销涨了近 3 倍）。
                    ForEach(Array(state.items.enumerated()), id: \.element.fingerprint) { index, item in
                        ClipCard(item: item, index: index, isSelected: index == selection,
                                 now: now, showsIndex: showsIndex,
                                 boardColorIndex: item.pinboardID.flatMap { boardColors[$0] })
                            .id(index)
                            // 拖拽和单击都交给 AppKit 层，见 CardDragSource：
                            // 需要"拖出卡片范围后缩略图变小"，SwiftUI 的静态预览做不到，
                            // 而且它的预览会实时渲染整张卡片，拖起来掉帧。
                            .overlay(
                                CardDragSource(clipID: item.id ?? -1) {
                                    // 手势回调在禁用隐式动画的事务里，动画得显式包
                                    withAnimation(Self.searchAnimation) { state.isSearching = false }
                                    if state.selection == index {
                                        state.onPaste?(false)
                                    } else {
                                        state.selection = index
                                    }
                                }
                            )
                            .contextMenu {
                                Menu(Localized.pin) {
                                    ForEach(state.pinboards) { board in
                                        Button {
                                            state.assign(item, to: board.id)
                                        } label: {
                                            Label {
                                                Text(board.name)
                                            } icon: {
                                                Image(nsImage: PinboardPalette.dotImage(board.colorIndex))
                                            }
                                        }
                                    }
                                    if !state.pinboards.isEmpty { Divider() }
                                    // 建一个新的并直接放进去 —— 想收藏时往往才意识到要开个新分类
                                    Button(Localized.createPinboard) {
                                        state.createPinboard(containing: item)
                                    }
                                }
                                if item.pinboardID != nil {
                                    Button(Localized.removeFromBoard) { state.assign(item, to: nil) }
                                }
                                Divider()
                                Button(Localized.deleteItem, role: .destructive) {
                                    if let id = item.id {
                                        try? ClipStore.shared.delete(id: id)
                                        state.reload()
                                    }
                                }
                            }
                            // 两段式：点未选中的卡片先选中它，点已选中的才执行粘贴。
                            // 单击即粘贴太容易手滑，把内容直接送进别人的输入框收不回来。
                    }
                }
                .padding(.horizontal, 20)
                // ScrollView 会裁掉超出边界的内容，阴影也算内容 —— 高度若正好等于卡片高，
                // 卡片阴影就会被切在边界上留下一条硬边。上下各留出 shadowRoom 给它扩散。
                .padding(.vertical, ClipCard.shadowRoom)
            }
            // 列表内容一变（搜索过滤、新增条目），原先的滚动位置就失效了，得把选中项带回视野。
            // anchor 用 nil 而不是 .leading —— 后者把卡片左边缘死死对齐可视区左边缘，
            // 会把那 20pt 内边距一起吃掉，第一张卡片就贴在面板边上了。
            .onChange(of: state.items.count) { _, _ in
                proxy.scrollTo(state.selection, anchor: nil)
            }
            // 每次打开面板回到列表开头。视图树现在是复用的（见 revision），
            // ScrollView 会记着上次关闭时停的位置。
            .onChange(of: revision) { _, _ in
                proxy.scrollTo(0, anchor: nil)
            }
            .onChange(of: state.selection) { _, new in
                // anchor 传 nil = 只滚动到「刚好让它完整可见」的最小距离，目标已在视野内时不动。
                // 用 .center 会把每一次选择都强行拖到正中，哪怕只是在相邻两张之间移动 ——
                // 那不是列表导航该有的手感。
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: nil) }
            }
            .overlay {
                // 自己画空状态，不用 ContentUnavailableView —— 它在这个非激活面板 + 玻璃
                // 背景下只渲染出一个白色小方块，文字压根不出来。
                if state.items.isEmpty { emptyState }
            }
        }
        // 64(工具栏) + 250(卡片区，含上下各 8 的阴影余量) + 18 = 332，仍精确填满面板。
        // 与之前相比卡片整体下移了 8pt。
        .frame(height: ClipCard.size.height + ClipCard.shadowRoom * 2)
        .padding(.bottom, 18)
    }
}

/// 图片卡片的缩略图缓存。
///
/// 不缓存的话 `NSImage(contentsOf:)` 会在**每次重绘**时从磁盘重读原图并解码 —— 一张截图
/// 动辄几千像素宽，滚动时逐帧解码必然卡死。卡片实际显示区域不到 240pt，降采样到 480 边长
/// 已经绰绰有余（留一倍给 Retina）。
enum Thumbnails {
    private static var cache: [String: NSImage] = [:]
    private static let maxSide: CGFloat = 480

    static func image(named blob: String) -> NSImage? {
        if let hit = cache[blob] { return hit }
        let url = ClipStore.shared.blobsURL.appendingPathComponent(blob)
        guard let source = NSImage(contentsOf: url) else { return nil }

        let longest = max(source.size.width, source.size.height)
        guard longest > maxSide else { cache[blob] = source; return source }

        let ratio = maxSide / longest
        let target = NSSize(width: source.size.width * ratio, height: source.size.height * ratio)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        cache[blob] = thumb
        return thumb
    }
}

/// 压在图片上的小底衬。
///
/// 底色直接取卡片自身的表面色 —— 落在卡片背景上时完全融为一体（看不出有底衬），
/// 落在图片上时才显出一小块灰色药丸。文字沿用和文本卡片一样的灰，整体只有一套配色。
private struct Pill: ViewModifier {
    /// 角标只有一个数字，用比尺寸文字更紧的左右边距才不显得空。
    var horizontal: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, horizontal)
            .padding(.vertical, 2.5)
            .background(Palette.surface, in: .capsule)
    }
}

/// 表示透明区域的棋盘格，图片卡片的衬底。
///
/// 走 AppKit 的 pattern fill 而不是 SwiftUI：`NSColor(patternImage:)` 是 CoreGraphics 原生
/// 的图案填充，且 layer-backed 的 NSView 会把绘制结果缓存进 layer，滚动时不重绘。
/// 先后试过两种更"SwiftUI"的写法都不行 —— Canvas 逐格绘制的 draw closure 每次布局都重跑；
/// `Image.resizable(resizingMode: .tile)` 实测也会拖慢滚动。
/// 透明图片的底纹。
///
/// 整块一次画好存成一张位图，之后就是贴图 —— 不用 `NSColor(patternImage:)` 循环填充，
/// 也不用 `NSView`：卡片尺寸是固定的，图案没有任何随内容变化的部分，实时算没有意义。
/// 这块底纹在滚动和拖拽截图时会被反复要求重绘，省下的就是这些次数。
private enum CheckerImage {
    static let shared: NSImage = {
        let size = ClipCard.size
        let cell: CGFloat = 9
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.16, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(white: 0.21, alpha: 1).setFill()
        var y: CGFloat = 0
        var row = 0
        while y < size.height {
            var x: CGFloat = row.isMultiple(of: 2) ? 0 : cell
            while x < size.width {
                NSRect(x: x, y: y, width: cell, height: cell).fill()
                x += cell * 2
            }
            y += cell
            row += 1
        }
        image.unlockFocus()
        return image
    }()
}

/// 工具栏上的图标按钮，悬停时浮出与标签一致的胶囊底色。
private struct ToolbarIconButton: View {
    let symbol: String
    let isActive: Bool
    /// 展开态下搜索图标已经在搜索条内部，不该再自带一层底色。
    let showsChrome: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                // 用等宽高的 frame + Circle，而不是 Capsule 配不等的 padding ——
                // 后者算出来是 30×26 的椭圆，一眼就能看出不圆。
                .frame(width: 28, height: 28)
                .background(hovering && showsChrome ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PinboardTab: View {
    let title: String, symbol: String
    let tint: Color?
    /// 是否展示文字。搜索展开时置 false，文字会被"挤"没而不是淡出。
    var showsTitle: Bool = true
    let isActive: Bool
    var renaming: Bool = false
    var onCommitName: ((String) -> Void)? = nil
    var onCancelName: (() -> Void)? = nil
    /// 当前正被拖拽的卡片 id；nil 表示没有进行中的内部拖拽（外来拖放一律拒收）。
    /// 用闭包惰性读取，不在 body 里建立对 draggingClipID 的依赖。
    var draggedClip: () -> Int64? = { nil }
    /// 有卡片拖到这个标签上松手时回调，参数是那条记录的 id。
    var onDropClip: ((Int64) -> Void)? = nil
    let action: () -> Void

    @State private var hovering = false
    /// 编辑中的名字。宽度跟着它走，所以要实时同步。
    @State private var draft = ""
    /// 文字的自然宽度。要做"挤压"动画就得有个具体的目标值 —— frame 在 nil 和 0 之间
    /// 是插值不出来的，必须量出来。
    @State private var titleWidth: CGFloat = 0
    @State private var dropTargeted = false

    var body: some View {
        Button(action: renaming ? {} : action) {
            HStack(spacing: showsTitle ? 5 : 0) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint ?? .secondary)
                if renaming {
                    // 用隐藏的原文字定住宽度，输入框以 overlay 叠在上面 —— 否则一进改名
                    // 标签宽度就跳一下，整条工具栏跟着重排。
                    //
                    // 必须是 overlay 而不是 ZStack：ZStack 的宽度取子视图最大值，而
                    // NSTextField 没有固有宽度上限，会把标签撑成横跨整条工具栏。
                    // overlay 的尺寸则跟随下面那个 Text。
                    // 宽度由这个隐藏 Text 决定：进场时等于原名（不跳变），随后跟着实时输入走。
                    Text(draft.isEmpty ? title : draft)
                        .font(.system(size: 13))
                        .opacity(0)
                        .frame(minWidth: 24)          // 清空时不至于塌成一条缝
                        .overlay {
                            InlineNameField(initial: title,
                                            onTextChange: { draft = $0 },
                                            onCommit: { onCommitName?($0) },
                                            onCancel: { onCancelName?() })
                                .frame(height: 17)
                        }
                } else if !title.isEmpty {
                    // 文字始终在视图树里，靠宽度动画到 0 + 裁剪被"挤"出去 —— 圆点因此
                    // 平滑地靠拢过来，和搜索条的展开是同一套运动。
                    // 换成条件插入（if）或淡出的话，圆点在动、文字却在褪色，两者对不上。
                    Text(title)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            GeometryReader { geo in
                                Color.clear.onAppear { titleWidth = geo.size.width }
                            }
                        )
                        .frame(width: showsTitle ? titleWidth : 0, alignment: .leading)
                        .clipped()
                }
            }
            .padding(.horizontal, showsTitle ? 11 : 7).padding(.vertical, 6)
            .background(isActive || hovering || renaming || dropTargeted
                        ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: Capsule())
            // 编辑态给一圈强调色描边，明确"焦点在这里"；拖拽悬停时同样描边，
            // 让人知道松手会落在哪个收藏夹
            .overlay {
                if renaming || dropTargeted {
                    Capsule().strokeBorder(Color.systemAccent, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 用 DropDelegate 而不是 .dropDestination —— 后者不暴露拖放操作类型，
        // 光标只能是默认的移动样式；这里要的是"带加号"的复制光标（DropProposal(.copy)），
        // 它同时也更准确：内容并没有从原处消失，只是多了个归属。
        .onDrop(of: [.text], delegate: PinboardDropDelegate(
            draggedClip: draggedClip,
            onDrop: { onDropClip?($0) },
            targeted: { dropTargeted = $0 }
        ))
    }
}

/// 单张剪贴板卡片：彩色顶栏 + 内容 + 底栏元信息。
///
/// 顶栏颜色：归入收藏夹的卡片用收藏夹的颜色（且不再显示来源图标 —— 归属压过来源），
/// 未归类的取来源 App 图标主色。两条都对标 Paste 的实际行为。
struct ClipCard: View {
    // 曾经实现过 Equatable + .equatable() 来跳过未变化的卡片（滚动确实更省），
    // 但列表内容变化时会出现"两张卡片同时高亮"——被判定为"没变"的卡片留着过期的
    // 选中态。正确性优先，先去掉；要再优化滚动请换别的路子，别动 identity 语义。
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    /// 相对时间的参考时刻，由 AppState 在 reload 时锁定，面板开着期间不变。
    let now: Date
    /// 是否显示右下角标 —— 只在按住 ⌘ 时为真。
    let showsIndex: Bool
    /// 所属收藏夹的调色板下标；nil = 未归类，顶栏用来源 App 主色。
    let boardColorIndex: Int?

    static let size = CGSize(width: 235, height: 234)
    static let gap: CGFloat = 21
    /// 留给卡片阴影与选中外框扩散的余量，不留就会被 ScrollView 的裁剪切掉。
    static let shadowRoom: CGFloat = 8
    /// 选中高亮框线宽。画在卡片外侧，所以要计入上面的余量。
    static let focusRing: CGFloat = 3
    /// 正文字号统一，不按内容长短缩放。
    static let bodyFontSize: CGFloat = 13
    private static let headerHeight: CGFloat = 50
    static let radius: CGFloat = 12   // 拖拽缩略图要按同一半径裁圆角，见 CardDragSource

    private var accent: Color {
        boardColorIndex.map(PinboardPalette.color) ?? AppAccent.color(forBundleID: item.sourceBundleID)
    }
    /// 顶栏文字色。收藏夹色的亮底（黄）要换深色文字，来源色顶栏维持白字。
    private var headerInk: Color {
        boardColorIndex.map(PinboardPalette.headerInk) ?? .white
    }
    /// 卡片底色不随选中变化 —— 选中只靠外圈高亮框表示，与原作一致。
    ///
    /// 用 `underPageBackgroundColor`（深色下 #282828）而不是 `windowBackgroundColor`（#1E1E1E）
    /// —— 卡片浮在玻璃之上，需要比"窗口底"更亮一档才立得起来。用语义色而非硬编码数值，
    /// 才能跟随浅/深色模式与「增强对比度」辅助功能设置。
    private var surface: Color { Palette.surface }
    private var ink: Color { .white }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        // 顺序要紧，两条都别调换：
        //   1. 先 .frame 定死卡片尺寸，两个底部 overlay 才有正确的参照系对齐；
        //   2. 渐变必须在 footer **之前**，否则它会连字符数和序号一起盖掉。
        .frame(width: Self.size.width, height: Self.size.height)
        .background(surface)
        // 底部淡出：盖一层「透明 → 卡片底色」的渐变。底色不透明，视觉上就是文字渐渐
        // 隐入背景，和给文字本身做渐变着色看不出区别，但那种写法要对每个字形做渐变
        // 求值 —— 受控实验里它是滚动掉帧的头号来源（23 → 8）。这里只是一层普通合成。
        .overlay(alignment: .bottom) {
            if item.kind != .image && item.kind != .color {
                LinearGradient(colors: [surface.opacity(0), surface],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 88)
                    .allowsHitTesting(false)
            }
        }
        // 底栏叠加而不是占一行：原作的内容区一直铺到卡片底部，字符数和序号浮在淡出的
        // 文字之上。做成 VStack 的独立一行会白白吃掉 30pt 的内容空间。
        .overlay(alignment: .bottom) { footer }
        .clipShape(RoundedRectangle(cornerRadius: UserDefaults.standard.bool(forKey: "plainCard") ? 0 : Self.radius, style: .continuous))
        // 常驻的细描边用 separatorColor（系统标准 white@10%），在通透的玻璃上切出边界，
        // 这样不必靠加深玻璃 tint 换对比 —— 后者反而会让深色卡片陷进背景里。
        // 它用 strokeBorder（内描边）只占 1pt，不影响布局。
        .overlay {
            if !UserDefaults.standard.bool(forKey: "plainCard") {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }
        }
        // 选中高亮框画在卡片**外侧**：strokeBorder 是内描边，会把整条边压在内容上，
        // 看起来就像"框长在卡片里面"。改用 stroke（居中描边）再整体外扩半个线宽。
        .overlay {
            if !UserDefaults.standard.bool(forKey: "plainCard") {
                RoundedRectangle(cornerRadius: Self.radius + Self.focusRing / 2, style: .continuous)
                    .stroke(Color.systemAccent, lineWidth: Self.focusRing)
                    .padding(-Self.focusRing / 2)
                    .opacity(isSelected ? 1 : 0)
            }
        }
        // 不加投影：受控实验里卡片阴影让滚动掉帧从 11 涨到 23（阴影要走离屏渲染，
        // 每张可见卡片一层）。卡片已有 separatorColor 描边，在玻璃背景上足够分明。
    }

    private var header: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text(item.createdAt.relativeDescription(to: now))
                    .font(.system(size: 12))
                    .foregroundStyle(headerInk.opacity(0.85))
            }
            .foregroundStyle(headerInk)
            Spacer(minLength: 4)
            // 收藏夹卡片不显示来源图标（归属压过来源），与 Paste 一致。
            if boardColorIndex == nil, let icon = AppAccent.icon(forBundleID: item.sourceBundleID) {
                // 只给一层很轻的投影，让图标在同色系顶栏上有边界感（微信的绿图标压在绿顶栏
                // 那种情况）。试过的另外两条路都不行：套玻璃或描边会在图标画布四周的透明
                // 留白处显出一圈方框；把顶栏压暗又会让饱和色发脏（绿色降一档就成了墨绿）。
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.25), radius: 2.5, y: 1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .frame(height: Self.headerHeight)
        .background(accent)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch item.kind {
            case .image:
                if let blob = item.blobPath, let image = Thumbnails.image(named: blob) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Image(nsImage: CheckerImage.shared))
                } else {
                    symbolPlaceholder
                }
            case .file:
                VStack(spacing: 6) {
                    Image(systemName: "doc.fill").font(.system(size: 34)).foregroundStyle(ink.opacity(0.5))
                    Text((item.text.split(separator: "\n").first?.split(separator: "/").last).map(String.init) ?? "")
                        .font(.system(size: 12)).foregroundStyle(ink).lineLimit(2)
                }
            case .color:
                Rectangle().fill(Color(hex: item.text) ?? .gray)
            default:
                // 不设 lineLimit，让文字自然铺满内容区再被裁掉，底部用渐变淡出暗示"还有更多"，
                // 比截断成省略号更接近原作。只取前 400 字渲染 —— 再多也填不进这张卡片，
                // 但 Text 会老老实实把整串排版一遍，几千字的内容会白白拖慢滚动。
                Text(item.text.prefix(400))
                    .font(.system(size: Self.bodyFontSize))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .foregroundStyle(ink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var symbolPlaceholder: some View {
        Image(systemName: item.kind.symbol).font(.largeTitle).foregroundStyle(ink.opacity(0.4))
    }

    /// 底栏：次要信息居中，序号靠右 —— 与原作一致。
    ///
    /// 文本类的次要信息是纯文字；图片的尺寸压在真实像素上，必须自带底衬才读得出来。
    /// 角标只在按住 ⌘ 时出现，同样带底衬。
    private var footer: some View {
        ZStack {
            if item.kind == .image {
                Text(item.footerText).modifier(Pill())
            } else {
                Text(item.footerText).foregroundStyle(ink.opacity(0.45))
            }
            // 只给前 9 项：角标存在的唯一意义就是标出 ⌘1…⌘9 打哪一张，
            // 第 10 项之后没有对应快捷键，标了反而误导。
            if showsIndex, index < 9 {
                HStack { Spacer(); Text("\(index + 1)").modifier(Pill(horizontal: 5)) }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

// MARK: - 展示用格式化

extension ClipItem {
    /// 文本类显示字符数，其余显示捕获时算好的 `meta`。
    var footerText: String {
        if let meta { return meta }
        return Localized.characters(text.count)
    }
}

extension Date {
    /// 复用同一个 formatter：每张卡片每次重绘都新建一个开销不小。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    func relativeDescription(to reference: Date) -> String {
        Self.relativeFormatter.localizedString(for: self, relativeTo: reference)
    }
}

/// 轻量本地化。TODO: 条目变多后换成 String Catalog（.xcstrings）。
enum Localized {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }

    static var clipboard: String { isChinese ? "剪贴板" : "Clipboard" }
    static var search: String { isChinese ? "搜索" : "Search" }
    /// 新建的收藏夹跟原作一样叫「未命名」，不编号 —— 反正马上就要改名。
    static func newPinboardName(_ n: Int) -> String { isChinese ? "未命名" : "Untitled" }
    static var rename: String { isChinese ? "重命名…" : "Rename…" }
    // 就叫「删除」——它已经在收藏夹的右键菜单里，再重复一遍主语是噪音
    static var deleteBoard: String { isChinese ? "删除" : "Delete" }
    static var color: String { isChinese ? "颜色" : "Color" }
    static var newBoard: String { isChinese ? "新建收藏夹" : "New Pinboard" }
    // 叫「收藏」，和「收藏夹」同一套说法 —— 动词和名词对得上，不用在脑子里做一次翻译
    static var pin: String { isChinese ? "收藏" : "Pin" }
    static var createPinboard: String { isChinese ? "创建收藏夹…" : "New Pinboard…" }
    static var removeFromBoard: String { isChinese ? "移出收藏夹" : "Remove from Pinboard" }
    static var confirm: String { isChinese ? "确定" : "OK" }
    static var cancel: String { isChinese ? "取消" : "Cancel" }
    static var deleteItem: String { isChinese ? "删除" : "Delete" }
    static var emptySearch: String { isChinese ? "没有匹配项" : "No Results" }
    static var emptyBoard: String { isChinese ? "收藏夹为空" : "Pinboard is Empty" }
    static var emptyHistory: String { isChinese ? "剪贴板为空" : "Clipboard is Empty" }

    static func characters(_ n: Int) -> String {
        isChinese ? "\(n) 个字符" : (n == 1 ? "1 character" : "\(n) characters")
    }

    static func kind(_ kind: ClipKind) -> String {
        guard isChinese else {
            switch kind {
            case .text: return "Text"
            case .richText: return "Rich Text"
            case .link: return "Link"
            case .image: return "Image"
            case .file: return "File"
            case .color: return "Color"
            }
        }
        switch kind {
        case .text: return "文本"
        case .richText: return "富文本"
        case .link: return "链接"
        case .image: return "图片"
        case .file: return "文件"
        case .color: return "颜色"
        }
    }
}

extension ClipKind {
    var displayName: String { Localized.kind(self) }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .richText: "doc.richtext"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }
}

extension Color {
    /// 系统强调色 —— 跟随「系统设置 → 外观 → 强调色」。
    ///
    /// 用 `controlAccentColor` 而不是 SwiftUI 的 `.accentColor`：后者会被 asset catalog 里的
    /// AccentColor 覆盖，而这里要的正是用户的系统设置。写成计算属性而非 `static let`，
    /// 否则会把首次取到的颜色缓存住，用户改了系统强调色也不跟着变。
    static var systemAccent: Color { Palette.systemAccent }

    /// 解析 `#RRGGBB` / `#RRGGBBAA`，用于 color 类型卡片预览。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard let value = UInt32(s, radix: 16), s.count == 6 || s.count == 8 else { return nil }
        let hasAlpha = s.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}


/// 收藏夹标签的拖放处理。
///
/// 两件事：`DropProposal(operation: .copy)` 给出"带加号"的复制光标（SwiftUI 的
/// `.dropDestination` 不让指定操作类型），符合"内容不消失、只多个归属"的语义；
/// 落点数据从 `draggedClip`（即 AppState.draggingClipID）同步拿 —— 拖拽是纯内部的，
/// id 就在自己手里，走 NSItemProvider 的 XPC 往返每次要 10–25ms，松手的反馈就晚这么多，
/// 还会把外部拖进来的任意数字文本误当成卡片 id。没有内部拖拽时 validateDrop 直接拒收。
private struct PinboardDropDelegate: DropDelegate {
    let draggedClip: () -> Int64?
    let onDrop: (Int64) -> Void
    let targeted: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggedClip() != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropEntered(info: DropInfo) { targeted(true) }
    func dropExited(info: DropInfo) { targeted(false) }

    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        guard let clipID = draggedClip() else { return false }
        onDrop(clipID)
        return true
    }
}
