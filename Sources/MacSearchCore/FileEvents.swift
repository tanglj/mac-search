import CoreServices
import Foundation

struct FileEvent: Sendable {
    let path: String
    let flags: UInt32
    let id: UInt64

    var requiresFullScan: Bool {
        let mask = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped |
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        return flags & UInt32(mask) != 0
    }
}

struct PendingChanges: Sendable {
    var paths: Set<String> = []
    var fullScan = false
    var eventID: UInt64 = 0
    var firstReceived: TimeInterval
    var lastReceived: TimeInterval
}

struct EventCoalescer {
    static func minimalPaths(_ paths: [String]) -> [String] {
        var result: [String] = []
        for path in Set(paths).sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            if !result.contains(where: { Paths.contains($0, path) }) { result.append(path) }
        }
        return result
    }
}

/// Callback-only shared state. No SQLite or filesystem enumeration occurs while this lock is held.
final class EventInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private let roots: [IndexRoot]
    private let excluded: Set<String>
    private let capacity: Int
    private var pending: [Int64: PendingChanges] = [:]

    init(roots: [IndexRoot], databasePath: String, capacity: Int = 4096) {
        self.roots = roots
        self.capacity = capacity
        excluded = Set(["", "-wal", "-shm", "-journal", ".lock"].map {
            Paths.lexical(databasePath + $0)
        })
    }

    func receive(_ events: [FileEvent], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        condition.lock()
        defer { condition.unlock() }
        for event in events {
            if event.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let path = Paths.lexical(event.path)
            if excluded.contains(path) { continue }
            for root in roots {
                let rootPath = Paths.lexical(root.path)
                let withinRoot = Paths.contains(rootPath, path)
                // Dropped/wrapped notifications invalidate the entire stream, including other roots.
                let globalMask = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                    kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMustScanSubDirs
                let global = event.flags & UInt32(globalMask) != 0
                guard global || withinRoot || (event.requiresFullScan && Paths.contains(path, rootPath)) else { continue }
                var change = pending[root.id] ?? PendingChanges(firstReceived: now, lastReceived: now)
                change.eventID = max(change.eventID, event.id)
                change.lastReceived = now
                change.fullScan = change.fullScan || event.requiresFullScan || path == rootPath
                if !change.fullScan {
                    let parent = (path as NSString).deletingLastPathComponent
                    let suffix = String(parent.dropFirst(rootPath.count))
                    change.paths.insert(root.path + suffix)
                    if change.paths.count > capacity { change.fullScan = true }
                }
                if change.fullScan { change.paths.removeAll(keepingCapacity: false) }
                pending[root.id] = change
            }
        }
        condition.signal()
    }

    func takeReady(now: TimeInterval, debounce: TimeInterval) -> [Int64: PendingChanges] {
        condition.lock()
        defer { condition.unlock() }
        let ready = pending.filter { now >= min($0.value.lastReceived + debounce, $0.value.firstReceived + 2) }
        for id in ready.keys { pending.removeValue(forKey: id) }
        return ready
    }

    func wait(maximum: TimeInterval, debounce: TimeInterval) {
        condition.lock()
        defer { condition.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let next = pending.values.map { min($0.lastReceived + debounce, $0.firstReceived + 2) }.min()
        let interval = min(maximum, next.map { max(0.001, $0 - now) } ?? maximum)
        _ = condition.wait(until: Date(timeIntervalSinceNow: interval))
    }
}

final class FileEvents {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.macsearch.fsevents")
    private let inbox: EventInbox

    init(paths: [String], inbox: EventInbox) throws {
        self.inbox = inbox
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(inbox).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf
        let callback: FSEventStreamCallback = { _, context, count, paths, flags, ids in
            guard let context else { return }
            let receiver = Unmanaged<EventInbox>.fromOpaque(context).takeUnretainedValue()
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            // Bound transient allocations too; the inbox collapses excess scopes to full scans.
            var events: [FileEvent] = []
            for index in 0..<count {
                events.append(FileEvent(path: String(cString: names[index]), flags: flags[index], id: ids[index]))
                if events.count == 256 { receiver.receive(events); events.removeAll(keepingCapacity: true) }
            }
            if !events.isEmpty { receiver.receive(events) }
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                                FSEventStreamCreateFlags(flags)) else {
            throw SearchError.message("无法创建 FSEvents 监听流。")
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw SearchError.message("无法启动 FSEvents 监听，请检查目录和系统权限。")
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        // Drain callbacks before releasing the unretained context and stream.
        queue.sync {}
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
