import Foundation
import Dispatch
import Darwin
import MacSearchCore

struct CLIError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct MacSearchCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n\n使用 mac-search help 查看用法。\n".utf8))
            Foundation.exit(1)
        }
    }

    static func run(_ arguments: [String]) throws {
        var args = arguments
        var globalArgs: [String] = []
        while let first = args.first, first == "--database" || first == "--json" {
            globalArgs.append(args.removeFirst())
            if first == "--database", !args.isEmpty { globalArgs.append(args.removeFirst()) }
        }
        let databasePath = try consumeOption(&globalArgs, "--database") ?? IndexStore.defaultDatabasePath
        let json = consumeFlag(&globalArgs, "--json")
        guard globalArgs.isEmpty else { throw CLIError(message: "全局选项不能重复。") }
        if args.isEmpty || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
            printHelp()
            return
        }
        let command = args.removeFirst()
        switch command {
        case "roots": try roots(args, databasePath: databasePath, json: json)
        case "index": try index(args, databasePath: databasePath, json: json)
        case "search": try search(args, databasePath: databasePath, json: json)
        case "stats":
            guard args.isEmpty else { throw CLIError(message: "stats 不接受额外参数。") }
            try stats(databasePath: databasePath, json: json)
        default: throw CLIError(message: "未知命令：\(command)")
        }
    }

    static func roots(_ args: [String], databasePath: String, json: Bool) throws {
        guard let action = args.first else { throw CLIError(message: "请指定 roots add、list 或 remove。") }
        let store: IndexStore
        switch action {
        case "add":
            guard args.count == 2 else { throw CLIError(message: "用法：roots add <目录>") }
            store = try IndexStore(databasePath: databasePath, mode: .readWrite)
            let root = try store.addRoot(args[1])
            try printOutput(root, json: json)
        case "list":
            guard args.count == 1 else { throw CLIError(message: "用法：roots list") }
            store = try IndexStore(databasePath: databasePath)
            try printOutput(try store.roots(), json: json)
        case "remove":
            guard args.count == 2, let id = Int64(args[1]) else { throw CLIError(message: "用法：roots remove <ID>") }
            store = try IndexStore(databasePath: databasePath, mode: .readWrite)
            try store.removeRoot(id: id)
            print(json ? "{\"removed\":true}" : "已移除索引目录 \(id)。")
        default: throw CLIError(message: "未知 roots 操作：\(action)")
        }
    }

    static func index(_ args: [String], databasePath: String, json: Bool) throws {
        guard let action = args.first, ["rebuild", "watch"].contains(action) else {
            throw CLIError(message: "用法：index rebuild|watch [--root-id <ID>]；watch 可设置 --debounce-ms 500")
        }
        var rest = Array(args.dropFirst())
        var rootID: Int64?
        if let value = try consumeOption(&rest, "--root-id") {
            guard let id = Int64(value) else { throw CLIError(message: "--root-id 必须是整数。") }
            rootID = id
        }
        var debounce = 500
        if action == "watch", let value = try consumeOption(&rest, "--debounce-ms") {
            guard let parsed = Int(value), (100...2000).contains(parsed) else {
                throw CLIError(message: "--debounce-ms 必须为 100～2000 之间的整数。")
            }
            debounce = parsed
        }
        guard rest.isEmpty else { throw CLIError(message: "未知参数：\(rest.joined(separator: " "))") }
        let store = try IndexStore(databasePath: databasePath, mode: .readWrite)
        let cancelled = AtomicFlag()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signalQueue = DispatchQueue(label: "com.macsearch.signals")
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        interruptSource.setEventHandler { cancelled.set() }
        terminateSource.setEventHandler { cancelled.set() }
        interruptSource.resume()
        terminateSource.resume()
        defer {
            interruptSource.cancel()
            terminateSource.cancel()
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
        if action == "watch" {
            try store.watch(WatchOptions(rootID: rootID, debounceMilliseconds: debounce), shouldStop: { cancelled.value }) { update in
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    if let data = try? encoder.encode(update) {
                        FileHandle.standardOutput.write(data + Data([10]))
                    }
                } else {
                    let line = "[\(update.kind)] \(update.path ?? "") \(update.message)\n"
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            }
            return
        }
        let reports = try store.rebuild(rootID: rootID, shouldCancel: { cancelled.value }) { path, count in
            if !json { print("扫描中：\(path)（已发现 \(count) 项）") }
        }
        try printOutput(reports, json: json)
    }

    static func search(_ args: [String], databasePath: String, json: Bool) throws {
        guard let query = args.first else { throw CLIError(message: "用法：search <关键词> [--directory <目录>] [--ext <扩展名,...>] [--kind file|directory] [--limit <数量>]") }
        var rest = Array(args.dropFirst())
        let directory = try consumeOption(&rest, "--directory")
        let extensions = (try consumeOption(&rest, "--ext") ?? "").split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        let kindValue = try consumeOption(&rest, "--kind") ?? "all"
        guard let kind = EntryKind(rawValue: kindValue) else { throw CLIError(message: "--kind 必须是 file、directory 或 all。") }
        let limitValue = try consumeOption(&rest, "--limit") ?? "100"
        guard let limit = Int(limitValue) else { throw CLIError(message: "--limit 必须是整数。") }
        guard rest.isEmpty else { throw CLIError(message: "未知参数：\(rest.joined(separator: " "))") }
        let store = try IndexStore(databasePath: databasePath)
        try printOutput(try store.search(SearchOptions(query: query, directory: directory, extensions: extensions, kind: kind, limit: limit)), json: json)
    }

    static func stats(databasePath: String, json: Bool) throws {
        let store = try IndexStore(databasePath: databasePath)
        try printOutput(try store.statistics(), json: json)
    }

    static func consumeOption(_ args: inout [String], _ option: String) throws -> String? {
        guard let index = args.firstIndex(of: option) else { return nil }
        guard args.filter({ $0 == option }).count == 1 else {
            throw CLIError(message: "参数不能重复：\(option)")
        }
        guard index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else {
            throw CLIError(message: "参数缺少有效值：\(option)")
        }
        let value = args[index + 1]
        args.removeSubrange(index...index + 1)
        return value
    }

    static func consumeFlag(_ args: inout [String], _ flag: String) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    static func printOutput<T: Encodable>(_ value: T, json: Bool) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            print(String(decoding: data, as: UTF8.self))
        } else {
            switch value {
            case let roots as [IndexRoot]:
                for root in roots {
                    print("\(root.id)\t\(root.status)\t\(root.entryCount)\t\(root.path)")
                    if let eventID = root.lastEventID { print("  事件检查点：\(eventID)") }
                    if let error = root.lastError { print("  最近错误：\(error)") }
                }
            case let records as [FileRecord]:
                for record in records { print(record.path) }
            case let reports as [ScanReport]:
                for report in reports { print("已完成：\(report.path)，\(report.entryCount) 项，耗时 \(String(format: "%.2f", report.durationSeconds)) 秒") }
            case let root as IndexRoot: print("已添加：\(root.id)\t\(root.path)")
            case let stats as IndexStatistics:
                print("索引目录：\(stats.rootCount)\n条目：\(stats.entryCount)（文件 \(stats.fileCount)，目录 \(stats.directoryCount)）\n数据库：\(stats.databaseBytes) 字节\nSQLite：\(stats.sqliteVersion)\ntrigram：\(stats.trigramEnabled ? "启用" : "回退")")
            default: print(value)
            }
        }
    }

    static func printHelp() {
        print("""
        mac-search：本地文件名索引工具

        全局选项（放在命令之前）：--database <路径>  指定 SQLite 索引文件
                  --json            输出 JSON

        命令：
          roots add <目录>                         添加索引目录
          roots list                                列出索引目录
          roots remove <ID>                         移除索引目录及其索引
          index rebuild [--root-id <ID>]             全量重建索引
          index watch [--root-id <ID>]               监听变化并增量维护索引
            --debounce-ms <毫秒>  默认 500，范围 100～2000；Ctrl+C 停止
          search <关键词> [筛选选项]                 搜索文件名
            --directory <目录>  限定目录及其后代
            --ext pdf,docx      扩展名过滤
            --kind file|directory|all
            --limit <数量>      默认 100
          stats                                     查看索引统计
        """)
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); storage = true; lock.unlock() }
}
