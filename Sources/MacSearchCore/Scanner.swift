import Darwin
import Foundation

struct FileInfo {
    let device: dev_t
    let inode: ino_t
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modifiedAt: Int64
}

struct ScannedEntry {
    let path: String
    let name: String
    let parentPath: String
    let `extension`: String
    let size: Int64?
    let modifiedAt: Int64
    let isDirectory: Bool
}

struct FileScanner {
    let databasePath: String

    static func volumeIdentity(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        if let uuid = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            return "uuid:" + uuid
        }
        return String(try inspect(path).device)
    }

    static func record(_ path: String, info: FileInfo) -> ScannedEntry {
        let url = URL(fileURLWithPath: path)
        return ScannedEntry(path: path, name: url.lastPathComponent, parentPath: (path as NSString).deletingLastPathComponent,
                            extension: Paths.normalize(url.pathExtension), size: info.isDirectory ? nil : info.size,
                            modifiedAt: info.modifiedAt, isDirectory: info.isDirectory)
    }

    static func inspect(_ path: String) throws -> FileInfo {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw SearchError.message("无法读取路径 \(path)：\(String(cString: strerror(errno)))")
        }
        return FileInfo(device: info.st_dev, inode: info.st_ino,
                        isDirectory: info.st_mode & S_IFMT == S_IFDIR,
                        isSymbolicLink: info.st_mode & S_IFMT == S_IFLNK,
                        size: info.st_size, modifiedAt: Int64(info.st_mtimespec.tv_sec))
    }

    func scan(root: String, shouldCancel: () -> Bool, emit: (ScannedEntry) throws -> Void) throws {
        let rootInfo = try Self.inspect(root)
        guard rootInfo.isDirectory else { throw SearchError.message("索引根目录已不是目录：\(root)") }
        let canonicalRoot = Paths.canonical(root)
        let canonicalDatabase = Paths.canonical(databasePath)
        let excluded = Set(["", "-wal", "-shm", "-journal", ".lock"].map { canonicalDatabase + $0 })

        // Stream each directory rather than retaining a potentially million-entry URL array.
        func walk(_ directory: String, expected: FileInfo, depth: Int) throws {
            if shouldCancel() { throw SearchError.cancelled }
            guard depth < 512 else { throw SearchError.message("目录层级超过扫描限制：\(directory)") }
            guard let stream = opendir(directory) else {
                throw SearchError.message("无法扫描 \(directory)：\(String(cString: strerror(errno)))")
            }
            defer { closedir(stream) }
            var opened = stat()
            guard fstat(dirfd(stream), &opened) == 0,
                  opened.st_dev == expected.device, opened.st_ino == expected.inode else {
                throw SearchError.message("扫描期间目录被替换：\(directory)")
            }
            while true {
                if shouldCancel() { throw SearchError.cancelled }
                errno = 0
                guard let item = readdir(stream) else {
                    if errno != 0 {
                        throw SearchError.message("枚举目录失败 \(directory)：\(String(cString: strerror(errno)))")
                    }
                    break
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) {
                        String(validatingCString: $0)
                    }
                }
                guard let name else { throw SearchError.message("目录包含无法解码的文件名：\(directory)") }
                if name == "." || name == ".." { continue }
                let path = directory == "/" ? "/" + name : directory + "/" + name
                if excluded.contains(path) { continue }
                let info = try Self.inspect(path)
                if info.device != rootInfo.device { continue }
                let url = URL(fileURLWithPath: path)
                try emit(ScannedEntry(path: path, name: name, parentPath: directory,
                                      extension: Paths.normalize(url.pathExtension),
                                      size: info.isDirectory ? nil : info.size,
                                      modifiedAt: info.modifiedAt, isDirectory: info.isDirectory))
                if info.isDirectory && !info.isSymbolicLink {
                    let isPackage = try url.resourceValues(forKeys: [.isPackageKey]).isPackage ?? false
                    if !isPackage { try walk(path, expected: info, depth: depth + 1) }
                }
            }
        }
        try walk(canonicalRoot, expected: rootInfo, depth: 0)
        if shouldCancel() { throw SearchError.cancelled }
    }
}
