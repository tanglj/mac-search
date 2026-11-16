import CoreServices
import Foundation
import XCTest
@testable import MacSearchCore

final class ReconciliationTests: XCTestCase {
    var base: URL!
    var data: URL!
    var store: IndexStore!
    var rootID: Int64!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        data = base.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        store = try IndexStore(databasePath: base.appendingPathComponent("index.sqlite").path, mode: .readWrite)
        rootID = try store.addRoot(data.path).id
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: base)
    }

    func make(_ relative: String, content: String = "data") throws {
        let url = data.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func path(_ relative: String) -> String { Paths.canonical(data.path) + "/" + relative }

    func testSubtreeChangesPreserveOtherRowsAndCheckpoint() throws {
        try make("a/old.pdf")
        try make("b/stable.txt")
        _ = try store.reconcile(rootID: rootID, eventID: 1)
        let oldID = try store.database.scalar("SELECT id FROM files WHERE name = 'stable.txt'")
        try FileManager.default.removeItem(atPath: path("a/old.pdf"))
        try make("a/new.pdf", content: "longer content")
        _ = try store.reconcile(rootID: rootID, paths: [path("a")], eventID: 7)
        XCTAssertEqual(try store.search(SearchOptions(query: "new.pdf")).first?.size, 14)
        XCTAssertTrue(try store.search(SearchOptions(query: "old.pdf")).isEmpty)
        XCTAssertEqual(try store.database.scalar("SELECT id FROM files WHERE name = 'stable.txt'"), oldID)
        XCTAssertEqual(try store.roots()[0].lastEventID, "7")
        try make("a/new.pdf", content: "x")
        _ = try store.reconcile(rootID: rootID, paths: [path("a")], eventID: 8)
        XCTAssertEqual(try store.search(SearchOptions(query: "new.pdf")).first?.size, 1)
    }

    func testMoveAndDeleteDirectoryRemovesOldDescendantPaths() throws {
        try make("left/old/deep/report.pdf")
        try make("right/anchor.txt")
        _ = try store.reconcile(rootID: rootID, eventID: 1)
        try FileManager.default.moveItem(atPath: path("left/old"), toPath: path("right/new"))
        _ = try store.reconcile(rootID: rootID, paths: [path("left"), path("right")], eventID: 2)
        XCTAssertTrue(try store.search(SearchOptions(query: "report", directory: path("left"))).isEmpty)
        XCTAssertEqual(try store.search(SearchOptions(query: "report")).first?.path, path("right/new/deep/report.pdf"))
        try FileManager.default.removeItem(atPath: path("right/new"))
        _ = try store.reconcile(rootID: rootID, paths: [path("right/new/deep")], eventID: 3)
        XCTAssertTrue(try store.search(SearchOptions(query: "report")).isEmpty)
        XCTAssertEqual(try store.search(SearchOptions(query: "anchor")).count, 1)
    }

    func testFailedMultiScopeBatchKeepsAllRowsAndCheckpoint() throws {
        try make("a/old.txt")
        try make("b/retained.txt")
        _ = try store.reconcile(rootID: rootID, eventID: 42)
        try FileManager.default.removeItem(atPath: path("a/old.txt"))
        try make("a/new.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("b"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path("b")) }
        XCTAssertThrowsError(try store.reconcile(rootID: rootID, paths: [path("a"), path("b")], eventID: 100))
        XCTAssertEqual(try store.roots()[0].lastEventID, "42")
        XCTAssertEqual(try store.search(SearchOptions(query: "old.txt")).count, 1)
        XCTAssertTrue(try store.search(SearchOptions(query: "new.txt")).isEmpty)
        XCTAssertEqual(try store.search(SearchOptions(query: "retained")).count, 1)
    }

    func testPartialCancellationPreservesCheckpoint() throws {
        try make("a/original.txt")
        _ = try store.reconcile(rootID: rootID, eventID: 42)
        for i in 0..<520 { try make("a/item_\(i).txt") }
        var cancelled = false
        XCTAssertThrowsError(try store.reconcile(rootID: rootID, paths: [path("a")], eventID: 99,
                                                shouldCancel: { cancelled }, progress: { _, _ in cancelled = true }))
        XCTAssertEqual(try store.roots()[0].lastEventID, "42")
        XCTAssertTrue(try store.search(SearchOptions(query: "item_")).isEmpty)
    }

    func testScopeBoundarySymlinkAndPackageProtection() throws {
        try make("folder/file.txt")
        try make("folder-other/keep.txt")
        let root = Paths.canonical(data.path)
        XCTAssertEqual(try store.reconciliationScopes(root: root, paths: [path("folder"), path("folder/missing")]), [path("folder")])
        XCTAssertThrowsError(try store.reconcile(rootID: rootID, paths: [Paths.canonical(base.path)]))
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: outside.path)
        try make("Sample.app/Contents/internal.txt")
        _ = try store.reconcile(rootID: rootID, paths: [path("link/subdir"), path("Sample.app/Contents")])
        XCTAssertTrue(try store.search(SearchOptions(query: "secret")).isEmpty)
        XCTAssertTrue(try store.search(SearchOptions(query: "internal")).isEmpty)
        XCTAssertEqual(try store.search(SearchOptions(query: "keep")).count, 1)
    }

    func testVolumeMismatchPreservesIndexAndLegacyIdentityUpgrades() throws {
        try make("retained.txt")
        let device = try FileScanner.inspect(data.path).device
        try store.database.execute("UPDATE index_roots SET volume_identifier = ?", [.text(String(device))])
        _ = try store.reconcile(rootID: rootID, eventID: UInt64.max - 1)
        XCTAssertEqual(try store.roots()[0].lastEventID, String(UInt64.max - 1))
        try store.database.execute("UPDATE index_roots SET volume_identifier = 'uuid:wrong-volume'")
        XCTAssertThrowsError(try store.reconcile(rootID: rootID, eventID: UInt64.max))
        XCTAssertEqual(try store.roots()[0].lastEventID, String(UInt64.max - 1))
        XCTAssertEqual(try store.search(SearchOptions(query: "retained")).count, 1)
    }

    func testEventDebounceMergeOverflowAndLoss() throws {
        let root = try store.roots()[0]
        let inbox = EventInbox(roots: [root], databasePath: store.database.path, capacity: 2)
        let fileFlag = UInt32(kFSEventStreamEventFlagItemModified)
        inbox.receive([FileEvent(path: path("a/one.txt"), flags: fileFlag, id: 1)], now: 10)
        inbox.receive([FileEvent(path: path("a/two.txt"), flags: fileFlag, id: 2)], now: 10.3)
        XCTAssertTrue(inbox.takeReady(now: 10.5, debounce: 0.5).isEmpty)
        let change = try XCTUnwrap(inbox.takeReady(now: 10.9, debounce: 0.5)[rootID])
        XCTAssertEqual(change.paths, [path("a")])
        XCTAssertEqual(change.eventID, 2)
        XCTAssertFalse(change.fullScan)
        inbox.receive([FileEvent(path: path("a/x"), flags: fileFlag, id: 3),
                       FileEvent(path: path("b/x"), flags: fileFlag, id: 4),
                       FileEvent(path: path("c/x"), flags: fileFlag, id: 5)], now: 20)
        XCTAssertTrue(try XCTUnwrap(inbox.takeReady(now: 21, debounce: 0.5)[rootID]).fullScan)
        inbox.receive([FileEvent(path: "/unrelated", flags: UInt32(kFSEventStreamEventFlagKernelDropped), id: 6)], now: 30)
        XCTAssertTrue(try XCTUnwrap(inbox.takeReady(now: 31, debounce: 0.5)[rootID]).fullScan)
        inbox.receive([FileEvent(path: path("a/x"), flags: fileFlag, id: 7)], now: 40)
        inbox.receive([FileEvent(path: path("a/y"), flags: fileFlag, id: 8)], now: 41.9)
        XCTAssertFalse(inbox.takeReady(now: 42.01, debounce: 0.5).isEmpty)
    }

    func testEventExclusionsAndParentPathBoundaries() throws {
        let root = try store.roots()[0]
        let inbox = EventInbox(roots: [root], databasePath: path("index.sqlite"))
        let flag = UInt32(kFSEventStreamEventFlagItemModified)
        inbox.receive([FileEvent(path: path("index.sqlite-wal"), flags: flag, id: 1),
                       FileEvent(path: Paths.canonical(data.path) + "-other/x", flags: flag, id: 2)], now: 10)
        XCTAssertTrue(inbox.takeReady(now: 11, debounce: 0.5).isEmpty)
        XCTAssertEqual(EventCoalescer.minimalPaths(["/a", "/a/b", "/ab", "/a"]), ["/a", "/ab"])
        inbox.receive([FileEvent(path: Paths.canonical(data.path), flags: UInt32(kFSEventStreamEventFlagRootChanged), id: 0)], now: 20)
        XCTAssertTrue(try XCTUnwrap(inbox.takeReady(now: 21, debounce: 0.5)[rootID]).fullScan)
    }

    func testMissingEntryRemovalPublishesSubtreeAndPreservesNeighboursAndCheckpoint() throws {
        try make("folder/deep/report.txt")
        try make("folder-other/retained.txt")
        _ = try store.reconcile(rootID: rootID, eventID: 42)
        try FileManager.default.removeItem(atPath: path("folder"))
        XCTAssertTrue(try store.removeMissingEntry(rootID: rootID, path: path("folder")))
        XCTAssertTrue(try store.search(SearchOptions(query: "report")).isEmpty)
        XCTAssertTrue(try store.search(SearchOptions(query: "folder", directory: path("folder"))).isEmpty)
        XCTAssertEqual(try store.search(SearchOptions(query: "retained")).count, 1)
        XCTAssertEqual(try store.roots()[0].lastEventID, "42")
        let reader = try IndexStore(databasePath: store.database.path)
        XCTAssertTrue(try reader.search(SearchOptions(query: "report")).isEmpty)
        XCTAssertThrowsError(try reader.removeMissingEntry(rootID: rootID, path: path("folder")))
    }

    func testMissingEntryRemovalPreservesRecreatedFileAndDanglingSymlink() throws {
        try make("replacement.txt")
        _ = try store.rebuild()
        try FileManager.default.removeItem(atPath: path("replacement.txt"))
        try FileManager.default.createSymbolicLink(atPath: path("replacement.txt"), withDestinationPath: path("missing"))
        XCTAssertFalse(try store.removeMissingEntry(rootID: rootID, path: path("replacement.txt")))
        XCTAssertEqual(try store.search(SearchOptions(query: "replacement")).count, 1)
        try FileManager.default.removeItem(atPath: path("replacement.txt"))
        XCTAssertTrue(try store.removeMissingEntry(rootID: rootID, path: path("replacement.txt")))
        try make("replacement.txt")
        _ = try store.reconcile(rootID: rootID)
        XCTAssertEqual(try store.search(SearchOptions(query: "replacement")).count, 1)
    }

    func testMissingEntryRemovalRejectsUnavailableParentVolumeAndOutsidePaths() throws {
        try make("folder/report.txt")
        _ = try store.rebuild()
        try FileManager.default.removeItem(atPath: path("folder/report.txt"))
        XCTAssertThrowsError(try store.removeMissingEntry(rootID: rootID, path: data.path))
        XCTAssertThrowsError(try store.removeMissingEntry(rootID: rootID, path: base.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("folder"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path("folder")) }
        XCTAssertThrowsError(try store.removeMissingEntry(rootID: rootID, path: path("folder/report.txt")))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path("folder"))
        try store.database.execute("UPDATE index_roots SET volume_identifier = 'uuid:wrong'")
        XCTAssertThrowsError(try store.removeMissingEntry(rootID: rootID, path: path("folder/report.txt")))
        XCTAssertEqual(try store.search(SearchOptions(query: "report")).count, 1)
    }

    func testWatchValidationAndRecoveryFlags() throws {
        XCTAssertThrowsError(try store.watch(WatchOptions(rootID: -1)))
        XCTAssertThrowsError(try store.watch(WatchOptions(debounceMilliseconds: 0)))
        let reader = try IndexStore(databasePath: store.database.path)
        XCTAssertThrowsError(try reader.watch())
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
                     kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount] {
            XCTAssertTrue(FileEvent(path: path("file"), flags: UInt32(flag), id: 1).requiresFullScan)
        }
        XCTAssertFalse(FileEvent(path: path("file"), flags: UInt32(kFSEventStreamEventFlagItemModified), id: 1).requiresFullScan)
    }
}
