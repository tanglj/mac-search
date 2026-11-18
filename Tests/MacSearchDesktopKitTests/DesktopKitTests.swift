import Foundation
import XCTest
import MacSearchCore
import MacSearchDesktopKit

final class SnapshotCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var snapshots: [EngineSnapshot] = []
    func append(_ value: EngineSnapshot) {
        condition.lock(); snapshots.append(value); condition.broadcast(); condition.unlock()
    }
    func wait(generation: Int, timeout: TimeInterval = 10, predicate: (EngineSnapshot) -> Bool) -> EngineSnapshot? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while Date() < deadline {
            if let result = snapshots.last(where: { $0.generation == generation && predicate($0) }) { return result }
            _ = condition.wait(until: deadline)
        }
        return nil
    }
    func values(generation: Int) -> [EngineSnapshot] {
        condition.lock(); defer { condition.unlock() }
        return snapshots.filter { $0.generation == generation }
    }
}

final class DesktopKitTests: XCTestCase, @unchecked Sendable {
    var base: URL!
    var data: URL!
    var database: String!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        data = base.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        database = base.appendingPathComponent("index.sqlite").path
        try Data().write(to: data.appendingPathComponent("客户合同.pdf"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func testPauseManageResumeAndReleaseWriter() throws {
        let collector = SnapshotCollector()
        let session = EngineSession(databasePath: database) { collector.append($0) }
        let initial = session.submit(monitoring: false)
        XCTAssertNotNil(collector.wait(generation: initial) { !$0.isBusy && $0.error == nil })
        let addition = session.submit(.add([data.path]), monitoring: true)
        let watching = try XCTUnwrap(collector.wait(generation: addition) { $0.isWatching && !$0.isBusy })
        XCTAssertEqual(watching.statistics?.entryCount, 1)
        XCTAssertEqual(watching.roots.count, 1)
        let pause = session.submit(monitoring: false)
        XCTAssertNotNil(collector.wait(generation: pause) { !$0.isBusy && !$0.isWatching })
        let rebuilding = session.submit(.rebuild(nil), monitoring: true)
        XCTAssertNotNil(collector.wait(generation: rebuilding) { $0.isWatching && !$0.isBusy })
        let removing = session.submit(.remove(watching.roots[0].id), monitoring: true)
        let removed = try XCTUnwrap(collector.wait(generation: removing) { !$0.isBusy && $0.roots.isEmpty })
        XCTAssertEqual(removed.statistics?.entryCount, 0)
        let stopped = DispatchSemaphore(value: 0)
        session.shutdown { stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        let writer = try IndexStore(databasePath: database, mode: .readWrite)
        XCTAssertTrue(try writer.roots().isEmpty)
    }

    func testExternalWriterKeepsReadOnlySearchAvailable() throws {
        var writer: IndexStore? = try IndexStore(databasePath: database, mode: .readWrite)
        _ = try writer?.addRoot(data.path)
        _ = try writer?.rebuild()
        let collector = SnapshotCollector()
        let session = EngineSession(databasePath: database) { collector.append($0) }
        let generation = session.submit(monitoring: true)
        let snapshot = try XCTUnwrap(collector.wait(generation: generation) { $0.error != nil })
        XCTAssertFalse(snapshot.isWatching)
        XCTAssertEqual(snapshot.roots.count, 1)
        let reader = try IndexStore(databasePath: database)
        XCTAssertEqual(try reader.search(SearchOptions(query: "合同")).count, 1)
        writer = nil
        let retry = session.submit(monitoring: true)
        XCTAssertNotNil(collector.wait(generation: retry) { $0.isWatching && !$0.isBusy && $0.error == nil })
        let stopped = DispatchSemaphore(value: 0)
        session.shutdown { stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
    }

    func testSearchCancellationRollsBackAndConnectionRemainsUsable() throws {
        let writer = try IndexStore(databasePath: database, mode: .readWrite)
        for number in 0..<500 { try Data().write(to: data.appendingPathComponent("document_\(number).txt")) }
        _ = try writer.addRoot(data.path)
        _ = try writer.rebuild()
        let reader = try IndexStore(databasePath: database)
        var checks = 0
        XCTAssertThrowsError(try reader.search(SearchOptions(query: "无"), shouldCancel: {
            checks += 1
            return checks > 1
        })) { error in
            guard case SearchError.searchCancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try reader.search(SearchOptions(query: "合同")).count, 1)
        XCTAssertThrowsError(try reader.search(SearchOptions(query: "", limit: 100), shouldCancel: { true }))
        XCTAssertEqual(try reader.search(SearchOptions(query: "合同")).count, 1)
    }

    func testSearchActorReadsPublishedUpdatesAndCancellation() async throws {
        let writer = try IndexStore(databasePath: database, mode: .readWrite)
        _ = try writer.addRoot(data.path)
        _ = try writer.rebuild()
        let service = SearchService(databasePath: database)
        let initial = try await service.search(SearchOptions(query: "合同"))
        XCTAssertEqual(initial.files.count, 1)
        try Data().write(to: data.appendingPathComponent("updated.txt"))
        _ = try writer.rebuild()
        let updated = try await service.search(SearchOptions(query: "updated"))
        XCTAssertEqual(updated.files.count, 1)
        let task = Task {
            // Cancel before calling the actor, independent of executor scheduling speed.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.search(SearchOptions(query: ""))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch SearchError.searchCancelled {}
        catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func testCachedQueryInvalidatesAfterRebuildAndRemoval() async throws {
        let writer = try IndexStore(databasePath: database, mode: .readWrite)
        let root = try writer.addRoot(data.path)
        _ = try writer.rebuild()
        let service = SearchService(databasePath: database)
        let options = SearchOptions(query: "合同")
        let initial = try await service.search(options)
        XCTAssertEqual(initial.files.count, 1)
        let cached = try await service.search(options)
        XCTAssertEqual(cached.files.map(\.path), initial.files.map(\.path))
        XCTAssertEqual(cached.milliseconds, 0)

        let added = data.appendingPathComponent("新合同.docx")
        try Data().write(to: added)
        _ = try writer.rebuild()
        let updated = try await service.search(options)
        XCTAssertEqual(updated.files.count, 2)

        try FileManager.default.removeItem(at: added)
        XCTAssertTrue(try writer.removeMissingEntry(rootID: root.id, path: added.path))
        let removed = try await service.search(options)
        XCTAssertEqual(removed.files.map(\.path), initial.files.map(\.path))
    }
}
