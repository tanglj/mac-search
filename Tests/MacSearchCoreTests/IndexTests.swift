import Foundation
import XCTest
@testable import MacSearchCore

final class IndexTests: XCTestCase {
    private var directory: URL!
    private var database: String!
    private var store: IndexStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("index.sqlite").path
        store = try IndexStore(databasePath: database, mode: .readWrite)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testRebuildAndSearchSupportsUnicodeAndFilters() throws {
        try "正文".write(to: directory.appendingPathComponent("客户合同终稿.txt"), atomically: true, encoding: .utf8)
        try "PDF".write(to: directory.appendingPathComponent("annual_report_2026.pdf"), atomically: true, encoding: .utf8)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "".write(to: nested.appendingPathComponent("报告.pdf"), atomically: true, encoding: .utf8)
        _ = try store.addRoot(directory.path)
        let report = try store.rebuild()
        XCTAssertEqual(report[0].entryCount, 4)
        XCTAssertEqual(try store.search(SearchOptions(query: "报告", extensions: ["pdf"])).map(\.name), ["报告.pdf"])
        XCTAssertEqual(try store.search(SearchOptions(query: "report 2026")).map(\.name), ["annual_report_2026.pdf"])
        XCTAssertEqual(try store.search(SearchOptions(query: "报告", directory: nested.path)).map(\.name), ["报告.pdf"])
    }

    func testFailedScanKeepsPublishedEntries() throws {
        try "旧内容".write(to: directory.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try store.addRoot(directory.path)
        _ = try store.rebuild()
        XCTAssertEqual(try store.statistics().entryCount, 1)
        XCTAssertThrowsError(try store.rebuild(shouldCancel: { true }))
        XCTAssertEqual(try store.statistics().entryCount, 1)
    }

    func testOverlappingRootsAreRejected() throws {
        let child = directory.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        _ = try store.addRoot(directory.path)
        XCTAssertThrowsError(try store.addRoot(child.path))
    }

    private func file(_ name: String) throws {
        try Data("data".utf8).write(to: directory.appendingPathComponent(name))
    }

    func testRebuildRemovesDeletedEntriesWithoutDuplicates() throws {
        try file("old_report.pdf")
        let root = try store.addRoot(directory.path)
        _ = try store.rebuild()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("old_report.pdf"))
        try file("new_report.pdf")
        _ = try store.rebuild()
        _ = try store.rebuild()
        XCTAssertEqual(try store.statistics().entryCount, 1)
        XCTAssertTrue(try store.search(SearchOptions(query: "old_report")).isEmpty)
        XCTAssertEqual(try store.search(SearchOptions(query: "new_report")).count, 1)
        try store.removeRoot(id: root.id)
        XCTAssertEqual(try store.statistics().entryCount, 0)
        XCTAssertTrue(try store.search(SearchOptions(query: "new_report")).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new_report.pdf").path))
    }

    func testCancellationAfterBatchPreservesCompleteSnapshot() throws {
        try file("original.txt")
        _ = try store.addRoot(directory.path)
        _ = try store.rebuild()
        for index in 0..<520 { try file("replacement_\(index).txt") }
        var cancel = false
        XCTAssertThrowsError(try store.rebuild(shouldCancel: { cancel }, progress: { _, _ in cancel = true }))
        XCTAssertEqual(try store.search(SearchOptions(query: "", limit: 1000)).map(\.name), ["original.txt"])
        XCTAssertEqual(try store.roots()[0].status, "interrupted")
        _ = try store.rebuild()
        XCTAssertEqual(try store.statistics().entryCount, 521)
    }

    func testUnavailableRootAndPermissionFailurePreserveSnapshot() throws {
        let rootURL = directory.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data().write(to: rootURL.appendingPathComponent("retained.pdf"))
        _ = try store.addRoot(rootURL.path)
        _ = try store.rebuild()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rootURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path) }
        XCTAssertThrowsError(try store.rebuild())
        XCTAssertEqual(try store.statistics().entryCount, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        try FileManager.default.removeItem(at: rootURL)
        XCTAssertThrowsError(try store.rebuild())
        XCTAssertEqual(try store.search(SearchOptions(query: "retained")).first?.rootStatus, "unavailable")
    }

    func testLiteralPunctuationUnicodeAndFTSFallbackAreEquivalent() throws {
        let hadTrigram = try store.trigramEnabled()
        for name in ["100%_final.txt", "quote\"literal.txt", "café.txt", "客户合同终稿.txt", "👩‍💻计划.txt", "Straße.txt", ".hidden"] {
            try file(name)
        }
        _ = try store.addRoot(directory.path)
        _ = try store.rebuild()
        let queries = ["%_", "quote\"", "cafe\u{301}", "合同终", "合同", "👩‍💻", "STRASSE", "x' OR 1=1 --", ".hidden"]
        for query in queries {
            let accelerated = try store.search(SearchOptions(query: query)).map(\.name)
            try store.database.execute("UPDATE metadata SET value = '0' WHERE key = 'trigram'")
            let fallback = try store.search(SearchOptions(query: query)).map(\.name)
            try store.database.execute("UPDATE metadata SET value = ? WHERE key = 'trigram'", [.text(hadTrigram ? "1" : "0")])
            XCTAssertEqual(accelerated, fallback, query)
        }
        XCTAssertEqual(try store.search(SearchOptions(query: "100%_")).map(\.name), ["100%_final.txt"])
        XCTAssertEqual(try store.search(SearchOptions(query: "cafe\u{301}")).map(\.name), ["café.txt"])
    }

    func testDirectoryBoundaryRankingAndTypeFilters() throws {
        for name in ["folder", "folder-other"] {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data().write(to: url.appendingPathComponent("report.pdf"))
        }
        for name in ["report", "report-final", "annual-report"] { try file(name) }
        _ = try store.addRoot(directory.path)
        _ = try store.rebuild()
        let results = try store.search(SearchOptions(query: "report", limit: 2))
        XCTAssertEqual(results.map(\.name), ["report", "report-final"])
        XCTAssertEqual(try store.search(SearchOptions(query: "report", directory: directory.appendingPathComponent("folder").path)).count, 1)
        XCTAssertEqual(try store.search(SearchOptions(query: "", kind: .directory)).count, 2)
        XCTAssertEqual(try store.search(SearchOptions(query: "REPORT", extensions: [".PDF"], kind: .file)).count, 2)
        XCTAssertThrowsError(try store.search(SearchOptions(query: "", limit: 0)))
    }

    func testSymbolicLinksAndPackagesAreNotTraversed() throws {
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data().write(to: target.appendingPathComponent("unique.txt"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("loop"), withDestinationURL: directory)
        let app = directory.appendingPathComponent("Sample.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("internal.txt"))
        _ = try store.addRoot(directory.path)
        _ = try store.rebuild()
        XCTAssertEqual(try store.search(SearchOptions(query: "unique")).count, 1)
        XCTAssertEqual(try store.search(SearchOptions(query: "alias")).first?.isDirectory, false)
        XCTAssertTrue(try store.search(SearchOptions(query: "internal")).isEmpty)
    }

    func testWriterLockAndReadOnlyPersistence() throws {
        try file("persisted.txt")
        _ = try store.addRoot(directory.path)
        _ = try store.rebuild()
        XCTAssertThrowsError(try IndexStore(databasePath: database, mode: .readWrite))
        let reader = try IndexStore(databasePath: database)
        XCTAssertEqual(try reader.search(SearchOptions(query: "persisted")).count, 1)
        XCTAssertThrowsError(try reader.addRoot(directory.path))
        store = nil
        store = try IndexStore(databasePath: database, mode: .readWrite)
        XCTAssertEqual(try store.statistics().entryCount, 1)
    }

    func testInterruptedScanStateRecoversOnWriterOpen() throws {
        _ = try store.addRoot(directory.path)
        for status in ["scanning", "reconciling"] {
            try store.database.execute("UPDATE index_roots SET status = ?", [.text(status)])
            store = nil
            store = try IndexStore(databasePath: database, mode: .readWrite)
            XCTAssertEqual(try store.roots()[0].status, "interrupted")
            XCTAssertNotNil(try store.roots()[0].lastError)
        }
    }

    func testUnknownDatabaseVersionIsRejected() throws {
        try store.database.execute("PRAGMA user_version = 999")
        store = nil
        XCTAssertThrowsError(try IndexStore(databasePath: database))
        XCTAssertThrowsError(try IndexStore(databasePath: database, mode: .readWrite))
    }

    func testReadOnlyConnectionRecreatesMissingWALSidecars() throws {
        try file("checkpointed.txt")
        _ = try store.addRoot(directory.path)
        _ = try store.rebuild()
        try store.database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        store = nil
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database + suffix)
        }
        let reader = try IndexStore(databasePath: database)
        XCTAssertEqual(try reader.search(SearchOptions(query: "checkpointed")).count, 1)
        XCTAssertThrowsError(try reader.database.execute("DELETE FROM files"))
    }

    func testDenseAndSparseSearchRankingMatchesReferenceQuery() throws {
        for index in 0..<1100 { try file("document_\(index)_report_2026.txt") }
        for name in ["report", "report-final.txt", "unique-zebra.pdf", "\u{10FFFD}ending.txt"] { try file(name) }
        _ = try store.addRoot(directory.path)
        _ = try store.rebuild()
        for query in ["report", "port", "unique-zebra", "repo 2026", "absent", "", "\u{10FFFF}"] {
            let phrase = Paths.normalize(query)
            let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
            let filters = words.map { _ in "instr(normalized_name, ?) > 0" }.joined(separator: " AND ")
            let reference = try store.database.prepare("""
                SELECT path FROM files WHERE \(filters.isEmpty ? "1" : filters)
                ORDER BY CASE WHEN normalized_name = ? THEN 0
                              WHEN instr(normalized_name, ?) = 1 THEN 1 ELSE 2 END,
                         normalized_name COLLATE BINARY, path COLLATE BINARY LIMIT 100
                """)
            try reference.bind(words.map(SQLValue.text) + [.text(phrase), .text(phrase)])
            var expected: [String] = []
            while try reference.step() { expected.append(reference.text(0)) }
            XCTAssertEqual(try store.search(SearchOptions(query: query)).map(\.path), expected, query)
        }
    }
}
