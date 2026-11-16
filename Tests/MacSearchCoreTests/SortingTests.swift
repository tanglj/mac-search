import Foundation
import XCTest
@testable import MacSearchCore

final class SortingTests: XCTestCase {
    private var base: URL!
    private var data: URL!
    private var store: IndexStore!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        data = base.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        store = try IndexStore(databasePath: base.appendingPathComponent("index.sqlite").path, mode: .readWrite)
        _ = try store.addRoot(data.path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ path: String, size: Int, timestamp: TimeInterval) throws {
        let url = data.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: size).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: url.path)
    }

    func testNameSortingOverridesRelevanceInBothDirections() throws {
        for name in ["report", "report-extra", "a-report", "z-report"] {
            try write(name, size: 1, timestamp: 100)
        }
        _ = try store.rebuild()
        XCTAssertEqual(try store.search(SearchOptions(query: "report")).map(\.name), ["report", "report-extra", "a-report", "z-report"])
        XCTAssertEqual(try store.search(SearchOptions(query: "REPORT", sort: .name)).map(\.name), ["a-report", "report", "report-extra", "z-report"])
        XCTAssertEqual(try store.search(SearchOptions(query: "report", sort: .name, direction: .descending)).map(\.name), ["z-report", "report-extra", "report", "a-report"])
    }

    func testSizeSortingAppliesBeforeLimitAndKeepsFiltering() throws {
        for number in 0..<160 {
            try write(String(format: "item_report_%03d.txt", number), size: number, timestamp: Double(number))
        }
        try write("excluded.pdf", size: 1000, timestamp: 1000)
        _ = try store.rebuild()
        let options = SearchOptions(query: "report", extensions: ["txt"], kind: .file, limit: 3, sort: .size, direction: .descending)
        XCTAssertEqual(try store.search(options).map(\.size), [159, 158, 157])
        XCTAssertEqual(try store.search(SearchOptions(query: "report", limit: 2, sort: .size)).map(\.size), [0, 1])
        let accelerated = try store.search(options).map(\.path)
        try store.database.execute("UPDATE metadata SET value = '0' WHERE key = 'trigram'")
        XCTAssertEqual(try store.search(options).map(\.path), accelerated)
    }

    func testDirectoryAndTimestampOrderingAndNullsLast() throws {
        try write("a/report-old.txt", size: 10, timestamp: 100)
        try write("z/report-new.txt", size: 20, timestamp: 300)
        try write("z/report-tie.txt", size: 20, timestamp: 300)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("report-folder"), withIntermediateDirectories: true)
        _ = try store.rebuild()
        try store.database.execute("UPDATE files SET modified_at = NULL WHERE name = 'report-folder'")
        XCTAssertEqual(try store.search(SearchOptions(query: "report", kind: .file, sort: .parentPath)).map(\.name), ["report-old.txt", "report-new.txt", "report-tie.txt"])
        XCTAssertEqual(try store.search(SearchOptions(query: "report", kind: .file, sort: .parentPath, direction: .descending)).map(\.name), ["report-new.txt", "report-tie.txt", "report-old.txt"])
        XCTAssertEqual(try store.search(SearchOptions(query: "report", sort: .modifiedAt)).map(\.name), ["report-old.txt", "report-new.txt", "report-tie.txt", "report-folder"])
        XCTAssertEqual(try store.search(SearchOptions(query: "report", sort: .modifiedAt, direction: .descending)).map(\.name), ["report-new.txt", "report-tie.txt", "report-old.txt", "report-folder"])
        for direction in [SearchSortDirection.ascending, .descending] {
            XCTAssertEqual(try store.search(SearchOptions(query: "report", sort: .size, direction: direction)).last?.name, "report-folder")
        }
        XCTAssertEqual(try store.search(SearchOptions(query: "report", directory: data.appendingPathComponent("a").path, sort: .size, direction: .descending)).map(\.name), ["report-old.txt"])
    }
}
