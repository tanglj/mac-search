import CSQLite
import Darwin
import Foundation

enum SQLValue {
    case text(String), integer(Int64), null
}

private final class QueryCancellation {
    let check: () -> Bool
    init(_ check: @escaping () -> Bool) { self.check = check }
}

final class Statement {
    private let handle: OpaquePointer
    private let database: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SearchError.message("SQL 准备失败：\(String(cString: sqlite3_errmsg(database)))")
        }
        handle = statement
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let text):
                // Explicit byte length preserves literal names containing unusual Unicode.
                code = text.withCString {
                    sqlite3_bind_text(handle, index, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .integer(let number): code = sqlite3_bind_int64(handle, index, number)
            case .null: code = sqlite3_bind_null(handle, index)
            }
            guard code == SQLITE_OK else { throw failure() }
        }
    }

    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure()
        }
    }

    func text(_ column: Int32) -> String {
        guard let value = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: value)
    }

    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func optionalInteger(_ column: Int32) -> Int64? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : integer(column)
    }
    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : text(column)
    }
    private func failure() -> SearchError {
        .message("SQLite 操作失败：\(String(cString: sqlite3_errmsg(database)))")
    }
}

final class Database {
    let path: String
    let writable: Bool
    private var handle: OpaquePointer?
    private var lockFD: Int32 = -1

    init(path: String, writable: Bool) throws {
        self.path = Paths.canonical(path)
        self.writable = writable
        if writable {
            let parent = URL(fileURLWithPath: self.path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            lockFD = Darwin.open(self.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw SearchError.message("无法打开索引写入锁：\(String(cString: strerror(errno)))") }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lockFD)
                lockFD = -1
                throw SearchError.message("另一个进程正在写入此索引，请稍后重试。")
            }
        }
        // SQLite's system VFS can require write access to recreate missing WAL/SHM sidecars.
        // Readers never CREATE a database and use query_only to prohibit SQL writes.
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE
        var result = sqlite3_open_v2(self.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        if result != SQLITE_OK && !writable {
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            result = sqlite3_open_v2(self.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard result == SQLITE_OK else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            close()
            throw SearchError.message("无法打开索引库（\(self.path)）：\(reason)。请先添加目录。")
        }
        do {
            sqlite3_busy_timeout(handle, 5000)
            if !writable { try execute("PRAGMA query_only = ON") }
            try execute("PRAGMA foreign_keys = ON")
            if writable {
                try execute("PRAGMA journal_mode = WAL")
                try execute("PRAGMA synchronous = NORMAL")
                try execute("PRAGMA temp_store = FILE")
                try migrate()
                try ensureQueryIndexes()
                try execute("UPDATE index_roots SET status = 'interrupted', last_error = '上次扫描未完成，请重新构建索引' WHERE status IN ('scanning', 'reconciling')")
            } else {
                try execute("PRAGMA query_only = ON")
                guard try scalar("PRAGMA user_version") == 1 else {
                    throw SearchError.message("不支持的数据库版本。")
                }
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    private func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        guard let handle else { throw SearchError.message("数据库连接已关闭。") }
        return try Statement(database: handle, sql: sql)
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
    }

    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql)
        try statement.bind(values)
        return try statement.step() ? statement.integer(0) : 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func cancellable<T>(check: @escaping () -> Bool, _ body: () throws -> T) throws -> T {
        if check() { throw SearchError.searchCancelled }
        let context = QueryCancellation(check)
        sqlite3_progress_handler(handle, 1000, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<QueryCancellation>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
        }, Unmanaged.passUnretained(context).toOpaque())
        defer {
            sqlite3_progress_handler(handle, 0, nil, nil)
            withExtendedLifetime(context) {}
        }
        do { return try body() }
        catch {
            if check() { throw SearchError.searchCancelled }
            throw error
        }
    }

    private func migrate() throws {
        let version = try scalar("PRAGMA user_version")
        guard version == 0 || version == 1 else { throw SearchError.message("不支持的数据库版本：\(version)") }
        guard version == 0 else { return }
        try transaction {
            try execute("""
                CREATE TABLE index_roots (
                    id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,
                    status TEXT NOT NULL DEFAULT 'pending', bookmark_data BLOB,
                    volume_identifier TEXT, last_scan_at INTEGER, last_event_id TEXT, last_error TEXT
                )
                """)
            try execute("""
                CREATE TABLE files (
                    id INTEGER PRIMARY KEY, root_id INTEGER NOT NULL REFERENCES index_roots(id) ON DELETE CASCADE,
                    path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, parent_path TEXT NOT NULL,
                    normalized_name TEXT NOT NULL, extension TEXT NOT NULL DEFAULT '', size INTEGER,
                    modified_at INTEGER, is_directory INTEGER NOT NULL DEFAULT 0,
                    scan_generation INTEGER NOT NULL DEFAULT 0
                )
                """)
            for (name, column) in [("root", "root_id"), ("name", "normalized_name"), ("extension", "extension"), ("parent", "parent_path")] {
                try execute("CREATE INDEX idx_files_\(name) ON files(\(column))")
            }
            try execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            // Runtime probing allows older system SQLite versions to use the same query semantics.
            let supportsTrigram: Bool
            do {
                try execute("CREATE VIRTUAL TABLE temp.trigram_probe USING fts5(name, tokenize='trigram case_sensitive 1')")
                try execute("DROP TABLE temp.trigram_probe")
                supportsTrigram = true
            } catch { supportsTrigram = false }
            if supportsTrigram {
                try execute("CREATE VIRTUAL TABLE files_fts USING fts5(normalized_name, content='files', content_rowid='id', tokenize='trigram case_sensitive 1')")
                try execute("""
                    CREATE TRIGGER files_ai AFTER INSERT ON files BEGIN
                        INSERT INTO files_fts(rowid, normalized_name) VALUES (new.id, new.normalized_name);
                    END
                    """)
                try execute("""
                    CREATE TRIGGER files_ad AFTER DELETE ON files BEGIN
                        INSERT INTO files_fts(files_fts, rowid, normalized_name) VALUES ('delete', old.id, old.normalized_name);
                    END
                    """)
                try execute("""
                    CREATE TRIGGER files_au AFTER UPDATE ON files BEGIN
                        INSERT INTO files_fts(files_fts, rowid, normalized_name) VALUES ('delete', old.id, old.normalized_name);
                        INSERT INTO files_fts(rowid, normalized_name) VALUES (new.id, new.normalized_name);
                    END
                    """)
            }
            try execute("INSERT INTO metadata VALUES ('trigram', ?)", [.text(supportsTrigram ? "1" : "0")])
            try execute("PRAGMA user_version = 1")
        }
    }

    /// These indexes are added lazily so existing databases benefit without a
    /// destructive rebuild or a schema-version bump.
    private func ensureQueryIndexes() throws {
        try execute("CREATE INDEX IF NOT EXISTS idx_files_root_name ON files(root_id, normalized_name COLLATE BINARY)")
        try execute("CREATE INDEX IF NOT EXISTS idx_files_extension_name ON files(extension, normalized_name COLLATE BINARY)")
        try execute("CREATE INDEX IF NOT EXISTS idx_files_modified ON files(modified_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_files_size ON files(size)")
    }
}
