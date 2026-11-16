import Foundation

extension IndexStore {
    public func search(_ options: SearchOptions, shouldCancel: @escaping () -> Bool = { false }) throws -> [FileRecord] {
        guard (1...10_000).contains(options.limit) else { throw SearchError.message("结果条数必须在 1～10000 之间。") }
        // All ranking phases observe one snapshot even if another process publishes a rebuild.
        try database.execute("BEGIN DEFERRED")
        do {
            let results = try database.cancellable(check: shouldCancel) { try rankedSearch(options) }
            try database.execute("COMMIT")
            return results
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func rankedSearch(_ options: SearchOptions) throws -> [FileRecord] {
        let keywords = Paths.normalize(options.query).split(whereSeparator: \.isWhitespace).map(String.init)
        let phrase = keywords.joined(separator: " ")
        var filters: [String] = []
        var filterValues: [SQLValue] = []
        if let directory = options.directory {
            let path = Paths.canonical(directory)
            let prefix = path == "/" ? "/" : path + "/"
            filters.append("(f.path = ? OR instr(f.path, ?) = 1)")
            filterValues += [.text(path), .text(prefix)]
        }
        if !options.extensions.isEmpty {
            let extensions = options.extensions.map { Paths.normalize($0.hasPrefix(".") ? String($0.dropFirst()) : $0) }
            filters.append("f.extension IN (\(Array(repeating: "?", count: extensions.count).joined(separator: ",")))")
            filterValues += extensions.map(SQLValue.text)
        }
        switch options.kind {
        case .file: filters.append("f.is_directory = 0")
        case .directory: filters.append("f.is_directory = 1")
        case .all: break
        }

        func fetch(_ conditions: [String], values: [SQLValue], limit: Int, orderedScan: Bool = false,
                   orderBy: String = "f.normalized_name COLLATE BINARY, f.path COLLATE BINARY") throws -> [FileRecord] {
            let clause = (filters + conditions).joined(separator: " AND ")
            let statement = try database.prepare("""
                SELECT f.path, f.name, f.parent_path, f.extension, f.size, f.modified_at, f.is_directory, r.status
                FROM files f \(orderedScan ? "INDEXED BY idx_files_name" : "")
                JOIN index_roots r ON r.id = f.root_id
                WHERE \(clause.isEmpty ? "1" : clause)
                ORDER BY \(orderBy) LIMIT ?
                """)
            try statement.bind(filterValues + values + [.integer(Int64(limit))])
            var result: [FileRecord] = []
            while try statement.step() {
                result.append(FileRecord(path: statement.text(0), name: statement.text(1), parentPath: statement.text(2),
                                         extension: statement.text(3), size: statement.optionalInteger(4),
                                         modifiedAt: statement.optionalInteger(5), isDirectory: statement.integer(6) == 1,
                                         rootStatus: statement.text(7)))
            }
            return result
        }

        if options.sort != .relevance {
            var conditions = keywords.map { _ in "instr(f.normalized_name, ?) > 0" }
            var values = keywords.map(SQLValue.text)
            let longWords = keywords.filter { $0.unicodeScalars.count >= 3 && !$0.contains("\0") }
            if try trigramEnabled(), !longWords.isEmpty {
                let expression = longWords.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
                conditions.append("f.id IN (SELECT rowid FROM files_fts WHERE files_fts MATCH ?)")
                values.append(.text(expression))
            }
            // Column and direction come only from enums. Sort the whole match set before LIMIT.
            let column: String
            switch options.sort {
            case .name, .relevance: column = "f.normalized_name COLLATE BINARY"
            case .parentPath: column = "f.parent_path COLLATE BINARY"
            case .modifiedAt: column = "f.modified_at"
            case .size: column = "f.size"
            }
            let direction = options.direction == .ascending ? "ASC" : "DESC"
            let nullsLast = options.sort == .size ? "f.size IS NULL, " : (options.sort == .modifiedAt ? "f.modified_at IS NULL, " : "")
            return try fetch(conditions, values: values, limit: options.limit,
                             orderBy: "\(nullsLast)\(column) \(direction), f.normalized_name COLLATE BINARY, f.path COLLATE BINARY")
        }

        // Split ranking into bounded queries; sorting every matching row defeats LIMIT for common words.
        var result = try fetch(["f.normalized_name = ?"], values: [.text(phrase)], limit: options.limit)
        if result.count == options.limit { return result }
        var prefixConditions = ["f.normalized_name >= ?", "f.normalized_name != ?", "instr(f.normalized_name, ?) = 1"]
        var prefixValues: [SQLValue] = [.text(phrase), .text(phrase), .text(phrase)]
        if let upperBound = prefixUpperBound(phrase) {
            prefixConditions.append("f.normalized_name < ?")
            prefixValues.append(.text(upperBound))
        }
        result += try fetch(prefixConditions, values: prefixValues, limit: options.limit - result.count, orderedScan: true)
        if result.count == options.limit || phrase.isEmpty { return result }

        var conditions = ["instr(f.normalized_name, ?) != 1"]
        var values: [SQLValue] = [.text(phrase)]
        for keyword in keywords {
            conditions.append("instr(f.normalized_name, ?) > 0")
            values.append(.text(keyword))
        }
        var orderedScan = true
        let longWords = keywords.filter { $0.unicodeScalars.count >= 3 && !$0.contains("\0") }
        if try trigramEnabled(), !longWords.isEmpty {
            // Bound candidate materialization. Sparse queries use FTS; dense queries stop early in name order.
            let expression = longWords.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            let candidateQuery = try database.prepare("SELECT rowid FROM files_fts WHERE files_fts MATCH ? LIMIT 1025")
            try candidateQuery.bind([.text(expression)])
            var candidates: [Int64] = []
            while try candidateQuery.step() { candidates.append(candidateQuery.integer(0)) }
            if candidates.isEmpty { return result }
            if candidates.count <= 1024 {
                conditions.append("f.id IN (\(Array(repeating: "?", count: candidates.count).joined(separator: ",")))")
                values += candidates.map(SQLValue.integer)
                orderedScan = false
            }
        }
        result += try fetch(conditions, values: values, limit: options.limit - result.count, orderedScan: orderedScan)
        return result
    }

    /// The exclusive BINARY upper bound for a Unicode prefix (UTF-8 preserves scalar ordering).
    private func prefixUpperBound(_ prefix: String) -> String? {
        var scalars = Array(prefix.unicodeScalars)
        while let last = scalars.popLast() {
            if last.value == 0x10FFFF { continue }
            var next = last.value + 1
            if (0xD800...0xDFFF).contains(next) { next = 0xE000 }
            guard let scalar = UnicodeScalar(next) else { continue }
            return String(String.UnicodeScalarView(scalars + [scalar]))
        }
        return nil
    }
}
