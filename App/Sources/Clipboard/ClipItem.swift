import Foundation
import GRDB

/// 剪贴板条目的语义类型。决定卡片渲染方式与筛选分类。
nonisolated enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, richText, link, image, file, color
}

/// 一条剪贴板记录。
///
/// 大数据（图片、RTF）不入库：`payload` 落在 Storage/blobs/ 下，库里只留相对路径。
/// SQLite 单行超过几百 KB 会拖垮全表扫描与 FTS 重建，而剪贴板天然会积累大量截图。
nonisolated struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    var id: Int64?
    var kind: ClipKind
    /// 可搜索的纯文本。图片为 OCR/文件名占位，file 为路径。
    var text: String
    /// blobs/ 下的相对文件名，仅 image/richText 使用。
    var blobPath: String?
    var sourceBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var pinboardID: Int64?
    /// 卡片底栏展示的次要信息：文本是字符数，图片是尺寸，文件是路径。
    /// 与 `text` 分开是为了给 OCR 让位 —— 图片的 `text` 未来要放识别出的文字供搜索。
    var meta: String?
    /// 内容指纹，用于去重：重复复制同一内容时只更新 createdAt 而非插入新行。
    var fingerprint: String
}

nonisolated extension ClipItem: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clip"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 用户自建的分类板（对标 Paste 的 Pinboards）。
nonisolated struct Pinboard: Codable, Identifiable, Equatable, Sendable {
    var id: Int64?
    var name: String
    var position: Int
}

nonisolated extension Pinboard: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pinboard"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
