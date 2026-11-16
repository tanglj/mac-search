import Darwin
import Foundation
import MacSearchCore

/// Captures the item shown in the confirmation dialog, without following a leaf symlink.
public struct TrashRequest: Sendable {
    public let path: String
    private let device: dev_t
    private let inode: ino_t
    private let type: mode_t

    public init(path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw SearchError.message("文件路径无效。")
        }
        // Resolve parent aliases (such as /var) while preserving a leaf symlink itself.
        let parent = try Self.resolved((path as NSString).deletingLastPathComponent)
        let name = (path as NSString).lastPathComponent
        guard !["", ".", "..", "/"].contains(name) else { throw SearchError.message("文件路径无效。") }
        self.path = parent == "/" ? "/" + name : parent + "/" + name
        let info = try Self.inspect(self.path)
        device = info.st_dev
        inode = info.st_ino
        type = info.st_mode & S_IFMT
    }

    func validate(roots: [IndexRoot], databasePath: String) throws -> IndexRoot {
        guard let root = roots.first(where: { Self.contains($0.path, path) }), path != root.path else {
            throw SearchError.message("只能将索引目录内的条目移到废纸篓，不能移走索引根目录。")
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard try Self.resolved(parent) == parent else {
            throw SearchError.message("文件的上级目录已发生变化，请重新校验索引后再试。")
        }
        let info = try Self.inspect(path)
        guard info.st_dev == device, info.st_ino == inode, info.st_mode & S_IFMT == type else {
            throw SearchError.message("文件在确认期间已被替换，操作已取消，请重新选择。")
        }
        let database = try Self.resolved(databasePath)
        let protected = ["", "-wal", "-shm", "-journal", ".lock"].map { database + $0 }
        guard !protected.contains(path), !(type == S_IFDIR && Self.contains(path, database)) else {
            throw SearchError.message("不能移走正在使用的索引数据库或其所在目录。")
        }
        return root
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    private static func inspect(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw SearchError.message("无法读取文件 \(path)：\(String(cString: strerror(errno)))")
        }
        return info
    }

    private static func resolved(_ path: String) throws -> String {
        guard let resolved = realpath((path as NSString).expandingTildeInPath, nil) else {
            throw SearchError.message("无法检查路径 \(path)：\(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
