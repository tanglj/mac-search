import Foundation
import MacSearchCore

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

public enum EngineCommand: Sendable {
    case refresh, add([String]), remove(Int64), rebuild(Int64?)
    case trash(TrashRequest)
}

public struct EngineSnapshot: Sendable {
    public let generation: Int
    public let roots: [IndexRoot]
    public let statistics: IndexStatistics?
    public let activity: String
    public let isWatching: Bool
    public let isBusy: Bool
    public let error: String?
    public let removedPath: String?
}

/// All IndexStore instances and writer lifetimes stay on one serial worker queue.
public final class EngineSession: @unchecked Sendable {
    private let databasePath: String
    private let queue = DispatchQueue(label: "com.macsearch.desktop.writer", qos: .utility)
    private let lock = NSLock()
    private var current = CancellationFlag()
    private var generation = 0
    private struct PendingTrash {
        let generation: Int
        let request: TrashRequest
    }
    // Only accessed under lock. Jobs execute on the existing writer/watch context.
    private var watchingFlag: CancellationFlag?
    private var pendingTrash: [PendingTrash] = []
    private let onSnapshot: @Sendable (EngineSnapshot) -> Void
    private let trashItem: @Sendable (URL) throws -> Void

    public init(databasePath: String,
                trashItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                onSnapshot: @escaping @Sendable (EngineSnapshot) -> Void) {
        self.databasePath = databasePath
        self.trashItem = trashItem
        self.onSnapshot = onSnapshot
    }

    @discardableResult
    public func submit(_ command: EngineCommand = .refresh, monitoring: Bool) -> Int {
        lock.lock()
        generation += 1
        let revision = generation
        if case .trash(let request) = command, monitoring,
           watchingFlag === current, !current.isCancelled {
            pendingTrash.append(PendingTrash(generation: revision, request: request))
            lock.unlock()
            return revision
        }
        current.cancel()
        watchingFlag = nil
        pendingTrash.removeAll()
        let flag = CancellationFlag()
        current = flag
        lock.unlock()
        queue.async { [self] in
            var activeRevision = revision
            defer {
                lock.lock()
                if watchingFlag === flag { watchingFlag = nil }
                lock.unlock()
            }
            var cachedRoots: [IndexRoot] = []
            var cachedStatistics: IndexStatistics?
            func emit(_ store: IndexStore?, activity: String, watching: Bool = false, busy: Bool = false, error: String? = nil, refreshData: Bool = true, removedPath: String? = nil) {
                guard !flag.isCancelled else { return }
                if refreshData {
                    cachedRoots = (try? store?.roots()) ?? []
                    cachedStatistics = try? store?.statistics()
                }
                onSnapshot(EngineSnapshot(generation: activeRevision, roots: cachedRoots,
                                          statistics: cachedStatistics, activity: activity,
                                          isWatching: watching, isBusy: busy, error: error, removedPath: removedPath))
            }
            if case .refresh = command, flag.isCancelled { return }
            do {
                let writer = try IndexStore(databasePath: databasePath, mode: .readWrite)
                func performTrash(_ request: TrashRequest, watching: Bool) {
                    guard !flag.isCancelled else { return }
                    do {
                        let root = try request.validate(roots: writer.roots(), databasePath: databasePath)
                        emit(writer, activity: "正在移到废纸篓", watching: watching, busy: true, refreshData: false)
                        try trashItem(URL(fileURLWithPath: request.path))
                        do {
                            // Once the filesystem move succeeds, always finish its transaction.
                            if try writer.removeMissingEntry(rootID: root.id, path: request.path) {
                                emit(writer, activity: "已移到废纸篓", watching: watching, busy: true, refreshData: false, removedPath: request.path)
                            } else {
                                _ = try writer.reconcile(rootID: root.id, paths: [request.path], shouldCancel: { flag.isCancelled })
                            }
                        } catch {
                            emit(writer, activity: "索引需要校验", watching: watching, busy: true,
                                 error: "文件已移到废纸篓，但索引更新失败：\(error.localizedDescription)")
                        }
                    } catch {
                        emit(writer, activity: "文件操作失败", watching: watching, busy: true,
                             error: "无法移到废纸篓：\(error.localizedDescription)")
                    }
                }
                emit(writer, activity: "正在准备索引", busy: true)
                switch command {
                case .refresh: break
                case .add(let paths):
                    // Preserve successful additions and report failures for the remaining paths.
                    var failures: [String] = []
                    for path in paths {
                        do { _ = try writer.addRoot(path) }
                        catch { failures.append(error.localizedDescription) }
                    }
                    if !failures.isEmpty { emit(writer, activity: "目录添加完成", error: failures.joined(separator: "\n")) }
                case .remove(let id): try writer.removeRoot(id: id)
                case .rebuild(let id):
                    _ = try writer.rebuild(rootID: id, shouldCancel: { flag.isCancelled }) { path, count in
                        emit(writer, activity: "正在重建 \((path as NSString).lastPathComponent) · \(count) 项", busy: true, refreshData: false)
                    }
                case .trash(let request):
                    performTrash(request, watching: false)
                }
                guard !flag.isCancelled else { return }
                guard monitoring, !(try writer.roots()).isEmpty else {
                    emit(writer, activity: monitoring ? "添加目录以开始索引" : "自动更新已暂停")
                    return
                }
                var starting = true
                try writer.watch(onIdle: {
                    while let work = self.takeTrash(for: flag) {
                        activeRevision = work.generation
                        performTrash(work.request, watching: true)
                        emit(writer, activity: "自动更新已开启", watching: true)
                    }
                }, shouldStop: { flag.isCancelled }) { update in
                    switch update.kind {
                    case "started": emit(writer, activity: "正在校验索引目录", watching: true, busy: true)
                    case "ready":
                        starting = false
                        self.lock.lock()
                        if !flag.isCancelled { self.watchingFlag = flag }
                        self.lock.unlock()
                        emit(writer, activity: "自动更新已开启", watching: true)
                    case "error": emit(writer, activity: "部分目录等待重试", watching: true, busy: starting, error: update.message)
                    case "validated", "updated":
                        emit(writer, activity: starting ? "正在校验索引目录" : "自动更新已开启", watching: true, busy: starting)
                    default: break
                    }
                }
            } catch {
                if flag.isCancelled { return }
                // Do not accept more in-place jobs after the stream failed. Surface the
                // failure to the newest queued command instead of leaving its UI busy.
                lock.lock()
                if watchingFlag === flag { watchingFlag = nil }
                if current === flag, let newest = pendingTrash.last {
                    activeRevision = newest.generation
                    pendingTrash.removeAll()
                }
                lock.unlock()
                let reader = try? IndexStore(databasePath: databasePath)
                emit(reader, activity: "自动更新未启动", error: error.localizedDescription)
            }
        }
        return revision
    }

    private func takeTrash(for flag: CancellationFlag) -> PendingTrash? {
        lock.lock(); defer { lock.unlock() }
        guard current === flag, !flag.isCancelled, !pendingTrash.isEmpty else { return nil }
        return pendingTrash.removeFirst()
    }

    /// Cancellation wakes the watcher within its bounded wait; completion runs after the writer is released.
    public func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        current.cancel()
        watchingFlag = nil
        pendingTrash.removeAll()
        lock.unlock()
        queue.async { completion() }
    }
}
