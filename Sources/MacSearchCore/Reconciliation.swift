import Foundation
import Darwin

/// Event-driven reconciliation only removes old records after successful enumeration.
extension IndexStore {
    @discardableResult
    public func reconcile(rootID: Int64, paths: [String]? = nil, eventID: UInt64? = nil,
                          shouldCancel: () -> Bool = { false },
                          progress: (String, Int) -> Void = { _, _ in }) throws -> ScanReport {
        try requireWriter()
        let configuration = try database.prepare("SELECT path, volume_identifier FROM index_roots WHERE id = ?")
        try configuration.bind([.integer(rootID)])
        guard try configuration.step() else { throw SearchError.message("索引目录 ID 不存在：\(rootID)") }
        let rootPath = configuration.text(0)
        let expected = configuration.optionalText(1)
        _ = try configuration.step()
        let started = Date()
        let fullScan = paths == nil
        try database.execute("UPDATE index_roots SET status = ?, last_error = NULL WHERE id = ?",
                             [.text(fullScan ? "scanning" : "reconciling"), .integer(rootID)])
        do {
            if shouldCancel() { throw SearchError.cancelled }
            let rootInfo = try FileScanner.inspect(rootPath)
            guard rootInfo.isDirectory, !rootInfo.isSymbolicLink else {
                throw SearchError.message("根路径已不是实际目录：\(rootPath)")
            }
            let volumeIdentity = try FileScanner.volumeIdentity(rootPath)
            if let expected, expected != volumeIdentity && expected != String(rootInfo.device) {
                throw SearchError.message("根目录所在卷身份不匹配，保留旧索引：\(rootPath)")
            }
            let scopes = try paths.map { try reconciliationScopes(root: rootPath, paths: $0) } ?? [rootPath]
            guard !scopes.isEmpty else { throw SearchError.message("对账范围不能为空。") }
            try database.execute("DROP TABLE IF EXISTS temp.scan_entries")
            try database.execute("""
                CREATE TEMP TABLE scan_entries (
                    path TEXT PRIMARY KEY, name TEXT NOT NULL, parent_path TEXT NOT NULL,
                    normalized_name TEXT NOT NULL, extension TEXT NOT NULL, size INTEGER,
                    modified_at INTEGER, is_directory INTEGER NOT NULL
                )
                """)
            defer { try? database.execute("DROP TABLE IF EXISTS temp.scan_entries") }
            let insert = try database.prepare("INSERT OR REPLACE INTO temp.scan_entries VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
            var batch: [ScannedEntry] = []
            var count = 0
            func flush() throws {
                try database.transaction {
                    for entry in batch {
                        try insert.bind([.text(entry.path), .text(entry.name), .text(entry.parentPath),
                                         .text(Paths.normalize(entry.name)), .text(entry.extension),
                                         entry.size.map(SQLValue.integer) ?? .null, .integer(entry.modifiedAt),
                                         .integer(entry.isDirectory ? 1 : 0)])
                        try insert.step()
                    }
                }
                batch.removeAll(keepingCapacity: true)
            }
            func stage(_ entry: ScannedEntry) throws {
                batch.append(entry)
                count += 1
                if batch.count >= 512 {
                    try flush()
                    progress(rootPath, count)
                }
            }
            let scanner = FileScanner(databasePath: database.path)
            for scope in scopes {
                let before = try FileScanner.inspect(scope)
                guard before.device == rootInfo.device else { throw SearchError.message("扫描范围跨越挂载点：\(scope)") }
                if scope != rootPath { try stage(FileScanner.record(scope, info: before)) }
                try scanner.scan(root: scope, shouldCancel: shouldCancel, emit: stage)
                let after = try FileScanner.inspect(scope)
                guard before.inode == after.inode, before.device == after.device else {
                    throw SearchError.message("扫描期间目录被替换：\(scope)")
                }
            }
            try flush()
            let finalInfo = try FileScanner.inspect(rootPath)
            guard rootInfo.inode == finalInfo.inode, rootInfo.device == finalInfo.device,
                  try FileScanner.volumeIdentity(rootPath) == volumeIdentity else {
                throw SearchError.message("扫描期间根目录或卷发生变化，保留旧索引。")
            }
            if shouldCancel() { throw SearchError.cancelled }
            try database.transaction {
                for scope in scopes {
                    if scope == rootPath {
                        try database.execute("DELETE FROM files WHERE root_id = ?", [.integer(rootID)])
                    } else {
                        try database.execute("DELETE FROM files WHERE root_id = ? AND path = ?",
                                             [.integer(rootID), .text(scope)])
                        // Row-ID candidates use the UNIQUE path index, avoiding a scan of every row in the root.
                        // '/' followed by '0' is the exclusive BINARY upper bound of the descendant prefix.
                        try database.execute("""
                            DELETE FROM files WHERE root_id = ? AND id IN
                                (SELECT id FROM files WHERE path >= ? AND path < ?)
                            """, [.integer(rootID), .text(scope + "/"), .text(scope + "0")])
                    }
                }
                try database.execute("""
                    INSERT INTO files(root_id, path, name, parent_path, normalized_name, extension, size,
                                      modified_at, is_directory, scan_generation)
                    SELECT ?, path, name, parent_path, normalized_name, extension, size,
                           modified_at, is_directory, ? FROM temp.scan_entries
                    """, [.integer(rootID), .integer(Int64(Date().timeIntervalSince1970))])
                if shouldCancel() { throw SearchError.cancelled }
                try database.execute("""
                    UPDATE index_roots SET status = 'ready', last_scan_at = ?, last_error = NULL,
                                           last_event_id = ?, volume_identifier = ? WHERE id = ?
                    """, [.integer(Int64(Date().timeIntervalSince1970)), eventID.map { .text(String($0)) } ?? .null,
                           .text(volumeIdentity), .integer(rootID)])
            }
            progress(rootPath, count)
            return ScanReport(rootID: rootID, path: rootPath, entryCount: count,
                              durationSeconds: Date().timeIntervalSince(started))
        } catch {
            let status: String
            if case SearchError.cancelled = error { status = "interrupted" }
            else if access(rootPath, F_OK) != 0 && errno == ENOENT { status = "unavailable" }
            else { status = "error" }
            try? database.execute("UPDATE index_roots SET status = ?, last_error = ? WHERE id = ?",
                                  [.text(status), .text(error.localizedDescription), .integer(rootID)])
            throw error
        }
    }

    /// Never follow a changed symlink/package ancestor. Missing scopes move upward to a verifiable directory.
    func reconciliationScopes(root: String, paths: [String]) throws -> [String] {
        var scopes: [String] = []
        let rootDevice = try FileScanner.inspect(root).device
        for path in paths {
            let requested = Paths.lexical(path)
            // Foundation can shorten /private/var to /var; preserve the configured spelling.
            let lexicalRoot = Paths.lexical(root)
            guard Paths.contains(lexicalRoot, requested) else {
                throw SearchError.message("对账路径不属于索引目录：\(path)")
            }
            let suffix = String(requested.dropFirst(lexicalRoot.count))
            var current = root
            var candidate = root
            for part in suffix.split(separator: "/") {
                let next = current == "/" ? "/" + part : current + "/" + part
                var info = stat()
                if lstat(next, &info) != 0 {
                    guard errno == ENOENT || errno == ENOTDIR else {
                        throw SearchError.message("无法检查对账路径 \(next)：\(String(cString: strerror(errno)))")
                    }
                    break
                }
                if info.st_mode & S_IFMT != S_IFDIR || info.st_dev != rootDevice { break }
                if try URL(fileURLWithPath: next).resourceValues(forKeys: [.isPackageKey]).isPackage == true { break }
                current = next
                candidate = next
            }
            scopes.append(candidate)
        }
        return EventCoalescer.minimalPaths(scopes)
    }
}
