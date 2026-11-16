import Foundation
import XCTest
import MacSearchCore
@testable import MacSearchDesktopKit
@testable import MacSearchDesktop

final class DesktopModelTests: XCTestCase {
    @MainActor
    func testRemovalRefreshesBusyListAndRestoredFilesCanReappear() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let data = base.appendingPathComponent("data")
        let folder = data.appendingPathComponent("folder")
        let child = folder.appendingPathComponent("report.txt")
        let neighbour = data.appendingPathComponent("folder-other.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data().write(to: child)
        try Data().write(to: neighbour)
        let database = base.appendingPathComponent("index.sqlite").path
        let writer = try IndexStore(databasePath: database, mode: .readWrite)
        let root = try writer.addRoot(data.path)
        let folderPath = root.path + "/folder"
        let childPath = folderPath + "/report.txt"
        let neighbourPath = root.path + "/folder-other.txt"
        _ = try writer.rebuild()
        let model = DesktopModel(databasePath: database)
        model.hits = try writer.search(SearchOptions(query: "")).map(SearchHit.init)
        model.selection = childPath
        // A pending search from before the deletion must not put the old row back.
        model.scheduleSearch()
        try FileManager.default.removeItem(at: folder)
        XCTAssertTrue(try writer.removeMissingEntry(rootID: root.id, path: folder.path))
        model.apply(EngineSnapshot(generation: 0, roots: try writer.roots(), statistics: nil,
                                   activity: "已移到废纸篓", isWatching: false, isBusy: true,
                                   error: nil, removedPath: folderPath))
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.hits.map(\.id), [neighbourPath])
        XCTAssertEqual(model.selection, neighbourPath)
        try await waitForSearch(model)
        XCTAssertEqual(model.hits.map(\.id), [neighbourPath])

        // No permanent UI exclusion: files restored to the same path are searchable.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: child)
        _ = try writer.rebuild()
        model.scheduleSearch()
        try await waitForSearch(model)
        XCTAssertTrue(model.hits.contains(where: { $0.id == childPath }))
        model.shutdown {}
    }

    @MainActor
    private func waitForSearch(_ model: DesktopModel) async throws {
        let deadline = Date(timeIntervalSinceNow: 5)
        while model.isSearching && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.searchError)
    }
}
