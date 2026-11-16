import CoreServices
import Foundation

public struct WatchUpdate: Codable, Sendable {
    public let kind: String
    public let rootID: Int64?
    public let path: String?
    public let message: String
    public let scannedEntries: Int?
    public let eventID: String?
}

public struct WatchOptions: Sendable {
    public var rootID: Int64?
    public var debounceMilliseconds: Int

    public init(rootID: Int64? = nil, debounceMilliseconds: Int = 500) {
        self.rootID = rootID
        self.debounceMilliseconds = debounceMilliseconds
    }
}

extension IndexStore {
    /// Blocks until shouldStop returns true. Call on the store's serial execution context.
    /// onIdle runs on that same context; FSEvents continues collecting changes while it executes.
    public func watch(_ options: WatchOptions = WatchOptions(), onIdle: () -> Void = {},
                      shouldStop: () -> Bool = { false },
                      onUpdate: (WatchUpdate) -> Void = { _ in }) throws {
        try requireWriter()
        guard (100...2000).contains(options.debounceMilliseconds) else {
            throw SearchError.message("去抖时间必须在 100～2000ms 之间。")
        }
        let selected = try roots().filter { options.rootID == nil || options.rootID == $0.id }
        guard !selected.isEmpty else { throw SearchError.message("没有可监听的索引目录，请先添加目录或检查 ID。") }
        let inbox = EventInbox(roots: selected, databasePath: database.path)
        func watchPaths() -> [String] {
            var paths: [String] = []
            for root in selected {
                // Also watch a surviving ancestor so deletion/recreation and remounts can be noticed.
                var ancestor = URL(fileURLWithPath: root.path).deletingLastPathComponent().path
                while !FileManager.default.fileExists(atPath: ancestor) && ancestor != "/" {
                    ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
                }
                paths.append(ancestor)
                if FileManager.default.fileExists(atPath: root.path) { paths.append(root.path) }
            }
            return EventCoalescer.minimalPaths(paths)
        }
        var listener = try FileEvents(paths: watchPaths(), inbox: inbox)
        defer { listener.stop() }
        let baseline = FSEventsGetCurrentEventId()
        var failed: [Int64: (next: TimeInterval, delay: TimeInterval)] = [:]
        var appliedIDs: [Int64: UInt64] = [:]
        let debounce = Double(options.debounceMilliseconds) / 1000

        func update(_ kind: String, root: IndexRoot?, message: String, report: ScanReport? = nil, eventID: UInt64? = nil) {
            onUpdate(WatchUpdate(kind: kind, rootID: root?.id, path: root?.path, message: message,
                                 scannedEntries: report?.entryCount, eventID: eventID.map(String.init)))
        }
        func process(_ root: IndexRoot, paths: [String]?, eventID: UInt64) {
            guard !shouldStop() else { return }
            do {
                let checkpoint = paths == nil ? eventID : max(eventID, appliedIDs[root.id] ?? 0)
                let report = try reconcile(rootID: root.id, paths: paths, eventID: checkpoint, shouldCancel: shouldStop)
                appliedIDs[root.id] = checkpoint
                failed.removeValue(forKey: root.id)
                update(paths == nil ? "validated" : "updated", root: root,
                       message: paths == nil ? "根目录校验完成" : "增量对账完成", report: report, eventID: checkpoint)
            } catch {
                if case SearchError.cancelled = error { return }
                let delay = min((failed[root.id]?.delay ?? 2.5) * 2, 60)
                failed[root.id] = (ProcessInfo.processInfo.systemUptime + delay, delay)
                update("error", root: root, message: "\(error.localizedDescription)；\(Int(delay)) 秒后重试")
            }
        }
        update("started", root: nil, message: "监听已启动，正在校验 \(selected.count) 个根目录")
        for root in selected { process(root, paths: nil, eventID: baseline) }
        if !shouldStop() { update("ready", root: nil, message: "启动校验结束，等待文件变化；失败目录将自动重试") }
        while !shouldStop() {
            onIdle()
            if shouldStop() { break }
            let now = ProcessInfo.processInfo.systemUptime
            let changes = inbox.takeReady(now: now, debounce: debounce)
            for root in selected {
                if shouldStop() { break }
                if let change = changes[root.id] {
                    let fullScan = change.fullScan || failed[root.id] != nil
                    let id = fullScan ? FSEventsGetCurrentEventId() : max(change.eventID, baseline)
                    process(root, paths: fullScan ? nil : EventCoalescer.minimalPaths(Array(change.paths)), eventID: id)
                } else if let failure = failed[root.id], now >= failure.next {
                    process(root, paths: nil, eventID: FSEventsGetCurrentEventId())
                    if failed[root.id] == nil {
                        // Bind recreated paths while the old stream still covers the transition.
                        let replacement = try FileEvents(paths: watchPaths(), inbox: inbox)
                        listener.stop()
                        listener = replacement
                    }
                }
            }
            if !shouldStop() { inbox.wait(maximum: 1, debounce: debounce) }
        }
        update("stopped", root: nil, message: "监听已停止；下次启动会重新校验目录")
    }
}
