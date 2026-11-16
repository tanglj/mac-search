import Foundation
import XCTest
import MacSearchCore
@testable import MacSearchDesktopKit

final class TrashTests: XCTestCase {
    private var base: URL!
    private var data: URL!
    private var database: String!
    private var store: IndexStore!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        data = base.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        database = base.appendingPathComponent("index.sqlite").path
        store = try IndexStore(databasePath: database, mode: .readWrite)
        _ = try store.addRoot(data.path)
    }
    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: base)
    }

    func testRequestRejectsReplacementRootAndRedirectedParent() throws {
        let path = data.appendingPathComponent("item.txt")
        try Data().write(to: path)
        let request = try TrashRequest(path: path.path)
        try FileManager.default.moveItem(at: path, to: data.appendingPathComponent("original.txt"))
        try Data().write(to: path)
        XCTAssertThrowsError(try request.validate(roots: store.roots(), databasePath: database))
        XCTAssertThrowsError(try TrashRequest(path: data.path).validate(roots: store.roots(), databasePath: database))

        let nested = data.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("item.txt"))
        let nestedRequest = try TrashRequest(path: nested.appendingPathComponent("item.txt").path)
        let moved = data.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: nested, to: moved)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: moved)
        XCTAssertThrowsError(try nestedRequest.validate(roots: store.roots(), databasePath: database))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("item.txt").path))
    }

    func testSymlinkRequestKeepsTargetAndDatabaseIsProtected() throws {
        let link = data.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("missing-target"))
        XCTAssertNoThrow(try TrashRequest(path: link.path).validate(roots: store.roots(), databasePath: database))
        try store.removeRoot(id: store.roots()[0].id)
        _ = try store.addRoot(base.path)
        XCTAssertThrowsError(try TrashRequest(path: database).validate(roots: store.roots(), databasePath: database))
        let dbFolder = base.appendingPathComponent("db-folder")
        try FileManager.default.createDirectory(at: dbFolder, withIntermediateDirectories: true)
        let nestedDB = dbFolder.appendingPathComponent("database")
        try Data().write(to: nestedDB)
        XCTAssertThrowsError(try TrashRequest(path: dbFolder.path).validate(roots: store.roots(), databasePath: nestedDB.path))
    }

    func testTrashReconcilesPausedIndexAndFailureResumesWatcher() throws {
        let folder = data.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("child.txt"))
        let retained = data.appendingPathComponent("retained.txt")
        try Data().write(to: retained)
        let link = data.appendingPathComponent("retained-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: retained)
        _ = try store.rebuild()
        store = nil
        let destination = base.appendingPathComponent("simulated-trash")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let snapshots = SnapshotCollector()
        let session = EngineSession(databasePath: database, trashItem: { url in
            if url.lastPathComponent == "retained.txt" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        }) { snapshots.append($0) }
        defer {
            let stopped = DispatchSemaphore(value: 0)
            session.shutdown { stopped.signal() }
            XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        }
        let deleted = session.submit(.trash(try TrashRequest(path: folder.path)), monitoring: false)
        let snapshot = try XCTUnwrap(snapshots.wait(generation: deleted) { !$0.isBusy })
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.statistics?.entryCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("folder/child.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let reader = try IndexStore(databasePath: database)
        XCTAssertTrue(try reader.search(SearchOptions(query: "child")).isEmpty)

        let trashedLink = session.submit(.trash(try TrashRequest(path: link.path)), monitoring: false)
        let linkSnapshot = try XCTUnwrap(snapshots.wait(generation: trashedLink) { !$0.isBusy })
        XCTAssertNil(linkSnapshot.error)
        XCTAssertEqual(linkSnapshot.statistics?.entryCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("retained-link").path), retained.path)

        let failure = session.submit(.trash(try TrashRequest(path: retained.path)), monitoring: true)
        XCTAssertNotNil(snapshots.wait(generation: failure) { $0.error != nil })
        XCTAssertNotNil(snapshots.wait(generation: failure) { $0.isWatching && !$0.isBusy })
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(try reader.search(SearchOptions(query: "retained")).count, 1)
    }

    func testExternalWriterPreventsTrashBeforeAnyFileChange() throws {
        let target = data.appendingPathComponent("protected-by-lock.txt")
        try Data().write(to: target)
        _ = try store.rebuild()
        let destination = base.appendingPathComponent("must-not-move.txt")
        let snapshots = SnapshotCollector()
        let session = EngineSession(databasePath: database, trashItem: { url in
            try FileManager.default.moveItem(at: url, to: destination)
        }) { snapshots.append($0) }
        let generation = session.submit(.trash(try TrashRequest(path: target.path)), monitoring: false)
        XCTAssertNotNil(snapshots.wait(generation: generation) { !$0.isBusy && $0.error != nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let stopped = DispatchSemaphore(value: 0)
        session.shutdown { stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
    }

    func testTrashPublishesRemovalBeforeWatcherValidation() throws {
        let target = data.appendingPathComponent("immediate.txt")
        try Data().write(to: target)
        _ = try store.rebuild()
        store = nil
        let destination = base.appendingPathComponent("simulated-trash.txt")
        let snapshots = SnapshotCollector()
        let validationStarted = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let session = EngineSession(databasePath: database, trashItem: { url in
            try FileManager.default.moveItem(at: url, to: destination)
        }) { snapshot in
            snapshots.append(snapshot)
            if snapshot.activity == "正在校验索引目录", snapshot.statistics?.entryCount == 0 {
                validationStarted.signal()
                _ = resume.wait(timeout: .now() + 5)
            }
        }
        defer {
            resume.signal()
            let stopped = DispatchSemaphore(value: 0)
            session.shutdown { stopped.signal() }
            XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        }
        let request = try TrashRequest(path: target.path)
        let generation = session.submit(.trash(request), monitoring: true)
        let removed = try XCTUnwrap(snapshots.wait(generation: generation, timeout: 2) { $0.removedPath == request.path })
        XCTAssertTrue(removed.isBusy)
        XCTAssertEqual(validationStarted.wait(timeout: .now() + 2), .success)
        let reader = try IndexStore(databasePath: database)
        XCTAssertTrue(try reader.search(SearchOptions(query: "immediate")).isEmpty)
    }

    func testWatchingTrashDoesNotRestartValidationAndSupportsConsecutiveCommands() throws {
        let first = data.appendingPathComponent("first.txt")
        let second = data.appendingPathComponent("second.txt")
        let unrelated = base.appendingPathComponent("unrelated")
        try Data().write(to: first)
        try Data().write(to: second)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data().write(to: unrelated.appendingPathComponent("retained.txt"))
        _ = try store.addRoot(unrelated.path)
        store = nil
        let snapshots = SnapshotCollector()
        let session = EngineSession(databasePath: database, trashItem: { url in
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(url.lastPathComponent))
        }) { snapshots.append($0) }
        defer {
            let stopped = DispatchSemaphore(value: 0)
            session.shutdown { stopped.signal() }
            XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unrelated.path)
        }
        let initial = session.submit(monitoring: true)
        XCTAssertNotNil(snapshots.wait(generation: initial) { $0.isWatching && !$0.isBusy })
        // The app's own process is ignored by FSEvents; no external event requests a rescan.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unrelated.path)
        for target in [first, second] {
            let generation = session.submit(.trash(try TrashRequest(path: target.path)), monitoring: true)
            let complete = try XCTUnwrap(snapshots.wait(generation: generation) { $0.isWatching && !$0.isBusy })
            XCTAssertNil(complete.error)
            XCTAssertFalse(snapshots.values(generation: generation).contains { $0.activity == "正在校验索引目录" || $0.error != nil })
            XCTAssertTrue(complete.roots.allSatisfy { $0.status == "ready" })
        }
        let reader = try IndexStore(databasePath: database)
        XCTAssertTrue(try reader.search(SearchOptions(query: "first")).isEmpty)
        XCTAssertTrue(try reader.search(SearchOptions(query: "second")).isEmpty)
        XCTAssertEqual(try reader.search(SearchOptions(query: "retained")).count, 1)
    }

    func testWatchingTrashKeepsExternalEventsAndFailureDoesNotRestartStream() throws {
        let folder = data.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let retained = folder.appendingPathComponent("failure.txt")
        let target = folder.appendingPathComponent("success.txt")
        let external = folder.appendingPathComponent("external-during-trash.txt")
        try Data().write(to: retained)
        try Data().write(to: target)
        store = nil
        let destination = base.appendingPathComponent("simulated-trash.txt")
        let snapshots = SnapshotCollector()
        let session = EngineSession(databasePath: database, trashItem: { url in
            if url.lastPathComponent == "failure.txt" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try FileManager.default.moveItem(at: url, to: destination)
            // Another process changes this scope while the writer is executing trash.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
            process.arguments = [external.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw SearchError.message("测试进程失败。") }
        }) { snapshots.append($0) }
        defer {
            let stopped = DispatchSemaphore(value: 0)
            session.shutdown { stopped.signal() }
            XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        }
        let initial = session.submit(monitoring: true)
        let baseline = try XCTUnwrap(snapshots.wait(generation: initial) { $0.isWatching && !$0.isBusy })
        let failed = session.submit(.trash(try TrashRequest(path: retained.path)), monitoring: true)
        XCTAssertNotNil(snapshots.wait(generation: failed) { $0.error != nil })
        XCTAssertNotNil(snapshots.wait(generation: failed) { $0.isWatching && !$0.isBusy })
        XCTAssertFalse(snapshots.values(generation: failed).contains { $0.activity == "正在校验索引目录" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        let successful = session.submit(.trash(try TrashRequest(path: target.path)), monitoring: true)
        XCTAssertNotNil(snapshots.wait(generation: successful) { $0.isWatching && !$0.isBusy })
        XCTAssertNotNil(snapshots.wait(generation: successful) {
            $0.statistics?.fileCount == 2 && $0.roots.first?.lastEventID != baseline.roots.first?.lastEventID
        })
        let reader = try IndexStore(databasePath: database)
        XCTAssertEqual(try reader.search(SearchOptions(query: "external-during-trash")).count, 1)
        XCTAssertTrue(try reader.search(SearchOptions(query: "success")).isEmpty)
        XCTAssertEqual(try reader.search(SearchOptions(query: "failure")).count, 1)
        XCTAssertFalse(snapshots.values(generation: successful).contains { $0.activity == "正在校验索引目录" })
    }

    func testCancelledWatchingTrashStillPublishesRemovalAndReleasesWriter() throws {
        let target = data.appendingPathComponent("cancelled.txt")
        try Data().write(to: target)
        store = nil
        let moved = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let destination = base.appendingPathComponent("simulated-trash.txt")
        let snapshots = SnapshotCollector()
        let session = EngineSession(databasePath: database, trashItem: { url in
            try FileManager.default.moveItem(at: url, to: destination)
            moved.signal()
            _ = resume.wait(timeout: .now() + 5)
        }) { snapshots.append($0) }
        defer { resume.signal(); session.shutdown() }
        let initial = session.submit(monitoring: true)
        XCTAssertNotNil(snapshots.wait(generation: initial) { $0.isWatching && !$0.isBusy })
        session.submit(.trash(try TrashRequest(path: target.path)), monitoring: true)
        XCTAssertEqual(moved.wait(timeout: .now() + 3), .success)
        let stopped = DispatchSemaphore(value: 0)
        session.shutdown { stopped.signal() }
        resume.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        let writer = try IndexStore(databasePath: database, mode: .readWrite)
        XCTAssertTrue(try writer.search(SearchOptions(query: "cancelled")).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSuccessfulTrashDoesNotDependOnReadableSiblings() throws {
        let target = data.appendingPathComponent("deleted-report.txt")
        let sibling = data.appendingPathComponent("unreadable")
        try Data().write(to: target)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data().write(to: sibling.appendingPathComponent("retained.txt"))
        _ = try store.rebuild()
        store = nil
        let destination = base.appendingPathComponent("simulated-trash.txt")
        let snapshots = SnapshotCollector()
        let session = EngineSession(databasePath: database, trashItem: { url in
            try FileManager.default.moveItem(at: url, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sibling.path)
        }) { snapshots.append($0) }
        defer {
            let stopped = DispatchSemaphore(value: 0)
            session.shutdown { stopped.signal() }
            XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sibling.path)
        }
        let generation = session.submit(.trash(try TrashRequest(path: target.path)), monitoring: false)
        XCTAssertNotNil(snapshots.wait(generation: generation) { !$0.isBusy })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let reader = try IndexStore(databasePath: database)
        XCTAssertTrue(try reader.search(SearchOptions(query: "deleted-report")).isEmpty)
        XCTAssertEqual(try reader.search(SearchOptions(query: "retained")).count, 1)
    }
}
