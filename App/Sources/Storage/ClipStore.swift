import Foundation
import GRDB
import os

/// 持久化层：SQLite（GRDB）+ FTS5 全文索引 + 文件系统 blob。
///
/// 选 GRDB 而非 SwiftData 的原因见 CLAUDE.md「存储」一节，核心是 SwiftData 无 FTS，
/// 搜索退化为全表 `contains` 线性扫描，而剪贴板历史会长到数万条。
nonisolated final class ClipStore: Sendable {
    static let shared = try! ClipStore()

    private let dbQueue: DatabaseQueue
    let blobsURL: URL

    /// ~/Library/Application Support/Copy/
    static var supportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Copy", isDirectory: true)
    }

    init() throws {
        let root = Self.supportURL
        blobsURL = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsURL, withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: root.appendingPathComponent("copy.sqlite").path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "pinboard") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "clip") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("blobPath", .text)
                t.column("sourceBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("pinboardID", .integer).references("pinboard", onDelete: .setNull)
                t.column("fingerprint", .text).notNull().unique()
            }
            // trigram 而非默认的 unicode61：unicode61 按空白/标点切词，整段中文会退化成
            // 单个 token，中文搜索直接失效。trigram 对中文、代码片段、子串匹配都有效。
            try db.create(virtualTable: "clipFTS", using: FTS5()) { t in
                t.synchronize(withTable: "clip")
                t.column("text")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
            }
        }
        m.registerMigration("v2_meta") { db in
            try db.alter(table: "clip") { $0.add(column: "meta", .text) }
        }
        return m
    }

    // MARK: - 写入

    /// 插入一条记录；若内容指纹已存在，仅把它提到最新（对标 Paste 的去重行为）。
    func insert(_ item: ClipItem) throws {
        try dbQueue.write { db in
            if var existing = try ClipItem.filter(Column("fingerprint") == item.fingerprint).fetchOne(db) {
                existing.createdAt = item.createdAt
                try existing.update(db)
            } else {
                var new = item
                try new.insert(db)
            }
        }
    }

    /// 把一条记录提到最新。
    ///
    /// 粘贴之后该条内容就是系统剪贴板的当前内容，理应回到历史第一位。不能靠自我捕获来
    /// 实现 —— 捕获路径被 `suppressNextChange()` 挡住了（否则会形成回环），而且那样记下的
    /// 来源会变成粘贴的目标 App，语义就错了。所以显式更新时间戳。
    func touch(id: Int64) throws {
        _ = try dbQueue.write { db in
            try ClipItem.filter(key: id).updateAll(db, Column("createdAt").set(to: Date()))
        }
    }

    func delete(id: Int64) throws {
        try dbQueue.write { db in
            if let item = try ClipItem.fetchOne(db, key: id), let blob = item.blobPath {
                try? FileManager.default.removeItem(at: blobsURL.appendingPathComponent(blob))
            }
            _ = try ClipItem.deleteOne(db, key: id)
        }
    }

    /// 保留期清理。`days == 0` 表示永久保留。
    func prune(olderThan days: Int) throws {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        try dbQueue.write { db in
            let stale = try ClipItem
                .filter(Column("createdAt") < cutoff && Column("pinboardID") == nil)
                .fetchAll(db)
            for item in stale {
                if let blob = item.blobPath {
                    try? FileManager.default.removeItem(at: blobsURL.appendingPathComponent(blob))
                }
            }
            _ = try ClipItem
                .filter(Column("createdAt") < cutoff && Column("pinboardID") == nil)
                .deleteAll(db)
        }
    }

    // MARK: - 读取

    /// 时间倒序取历史。`query` 非空时走 FTS5，否则直接翻表。
    /// 一次取多少条。
    ///
    /// 卡片用的是 HStack 而非 LazyHStack（原因见 ClipboardBarView 里的注释），所有条目
    /// 都会真的渲染，条数直接决定滚动开销。面板是"最近用过的"快速取用口，不是历史浏览器 ——
    /// 更早的内容靠搜索找，所以不必一次铺出几百张。
    static let pageSize = 100

    func recent(limit: Int = pageSize, query: String = "", pinboardID: Int64? = nil) throws -> [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return try dbQueue.read { db in
            // trigram 分词器要求匹配串 ≥3 字符；更短的查询退回 LIKE，否则会搜不到结果。
            if trimmed.count >= 3, let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) {
                var sql = """
                    SELECT clip.* FROM clip
                    JOIN clipFTS ON clipFTS.rowid = clip.id AND clipFTS MATCH ?
                    """
                var args: [any DatabaseValueConvertible] = [pattern]
                if let pinboardID {
                    sql += " WHERE clip.pinboardID = ?"
                    args.append(pinboardID)
                }
                sql += " ORDER BY clip.createdAt DESC LIMIT ?"
                args.append(limit)
                return try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }

            var request = ClipItem.all()
            if let pinboardID { request = request.filter(Column("pinboardID") == pinboardID) }
            if !trimmed.isEmpty { request = request.filter(Column("text").like("%\(trimmed)%")) }
            return try request.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    func pinboards() throws -> [Pinboard] {
        try dbQueue.read { try Pinboard.order(Column("position")).fetchAll($0) }
    }

    /// 数据库变更的观察流，供 UI 订阅（GRDB 会在事务提交后触发）。
    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking { try ClipItem.fetchCount($0) }
            .start(in: dbQueue, scheduling: .async(onQueue: .main),
                   onError: { Log.store.error("observe: \($0)") },
                   onChange: { _ in onChange() })
    }
}

nonisolated enum Log {
    static let store = Logger(subsystem: "dev.copyapp.Copy", category: "store")
    static let clipboard = Logger(subsystem: "dev.copyapp.Copy", category: "clipboard")
    static let system = Logger(subsystem: "dev.copyapp.Copy", category: "system")
}
