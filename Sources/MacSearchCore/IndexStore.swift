import CSQLite
import Foundation

/// Use one serial execution context per instance. Open separate read-only instances for concurrent searches.
public final class IndexStore {
    public enum OpenMode { case readOnly, readWrite }
    let database: Database

    public static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacSearch/index.sqlite").path
    }

    public init(databasePath: String = IndexStore.defaultDatabasePath, mode: OpenMode = .readOnly) throws {
        database = try Database(path: databasePath, writable: mode == .readWrite)
    }

    func requireWriter() throws {
        guard database.writable else { throw SearchError.message("此连接为只读模式。") }
    }

    @discardableResult
    public func addRoot(_ path: String) throws -> IndexRoot {
        try requireWriter()
        let canonical = Paths.canonical(path)
        let info = try FileScanner.inspect(canonical)
        guard info.isDirectory else { throw SearchError.message("索引根路径必须是目录：\(canonical)") }
        for root in try roots() {
            guard !Paths.contains(root.path, canonical), !Paths.contains(canonical, root.path) else {
                throw SearchError.message("目录与已有索引范围重叠：\(root.path)")
            }
        }
        try database.execute("INSERT INTO index_roots(path, volume_identifier) VALUES (?, ?)",
                             [.text(canonical), .text(try FileScanner.volumeIdentity(canonical))])
        guard let root = try roots().first(where: { $0.path == canonical }) else {
            throw SearchError.message("新增索引目录后无法读取记录。")
        }
        return root
    }

    public func removeRoot(id: Int64) throws {
        try requireWriter()
        guard try roots().contains(where: { $0.id == id }) else {
            throw SearchError.message("索引目录 ID 不存在：\(id)")
        }
        try database.transaction {
            try database.execute("DELETE FROM index_roots WHERE id = ?", [.integer(id)])
        }
    }

    public func roots() throws -> [IndexRoot] {
        let statement = try database.prepare("""
            SELECT r.id, r.path, r.status, r.last_scan_at, r.last_error,
                   (SELECT count(*) FROM files f WHERE f.root_id = r.id), r.last_event_id
            FROM index_roots r ORDER BY r.id
            """)
        var result: [IndexRoot] = []
        while try statement.step() {
            result.append(IndexRoot(id: statement.integer(0), path: statement.text(1),
                                    status: statement.text(2), lastScanAt: statement.optionalInteger(3),
                                    lastError: statement.optionalText(4), entryCount: statement.integer(5), lastEventID: statement.optionalText(6)))
        }
        return result
    }

    public func statistics() throws -> IndexStatistics {
        let statement = try database.prepare("SELECT sqlite_version()")
        _ = try statement.step()
        let directoryCount = try database.scalar("SELECT count(*) FROM files WHERE is_directory = 1")
        let total = try database.scalar("SELECT count(*) FROM files")
        let bytes = [database.path, database.path + "-wal", database.path + "-shm"].reduce(Int64(0)) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return try IndexStatistics(rootCount: database.scalar("SELECT count(*) FROM index_roots"),
                                   entryCount: total, fileCount: total - directoryCount,
                                   directoryCount: directoryCount, databaseBytes: bytes,
                                   sqliteVersion: statement.text(0), trigramEnabled: trigramEnabled())
    }

    func trigramEnabled() throws -> Bool {
        try database.scalar("SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'trigram'") == 1
    }

    public func rebuild(rootID: Int64? = nil, shouldCancel: () -> Bool = { false },
                        progress: (String, Int) -> Void = { _, _ in }) throws -> [ScanReport] {
        try requireWriter()
        let allRoots = try roots()
        let selected = allRoots.filter { rootID == nil || $0.id == rootID }
        guard !selected.isEmpty else { throw SearchError.message("没有可扫描的索引目录，请先添加目录或检查目录 ID。") }
        var reports: [ScanReport] = []
        for root in selected {
            if shouldCancel() { throw SearchError.cancelled }
            reports.append(try reconcile(rootID: root.id, shouldCancel: shouldCancel, progress: progress))
        }
        return reports
    }

}
