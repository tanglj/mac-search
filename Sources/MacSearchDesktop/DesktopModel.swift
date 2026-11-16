import AppKit
import Combine
import Foundation
import MacSearchCore
import MacSearchDesktopKit
import ServiceManagement

struct SearchHit: Identifiable {
    let file: FileRecord
    var id: String { file.path }
    var sortName: String { file.name }
    var sortDirectory: String { file.parentPath }
    var sortModified: Int64 { file.modifiedAt ?? .min }
    var sortSize: Int64 { file.size ?? .min }
}

@MainActor
final class DesktopModel: ObservableObject {
    @Published var query = ""
    @Published var extensionFilter = ""
    @Published var kind: EntryKind = .all
    @Published var scopeID: Int64?
    @Published var hits: [SearchHit] = []
    @Published var selection: String?
    @Published var sortOrder: [KeyPathComparator<SearchHit>] = []
    @Published var pendingTrash: TrashRequest?
    @Published var roots: [IndexRoot] = []
    @Published var statistics: IndexStatistics?
    @Published var activity = "正在启动"
    @Published var isBusy = true
    @Published var isWatching = false
    @Published var isSearching = false
    @Published var milliseconds: Double = 0
    @Published var errorMessage: String?
    @Published var searchError: String?
    @Published var showSettings = false
    @Published var showDirectories = false
    @Published var rootToRemove: IndexRoot?
    @Published var resultLimit = 100
    @Published var monitoring: Bool
    @Published var hotKeyEnabled: Bool
    @Published var hotKeyError: String?
    @Published var loginEnabled = false
    @Published var loginMessage = ""
    @Published var loginBusy = false
    let databasePath: String
    var toggleWindow: (() -> Void)?
    var hideWindow: (() -> Void)?
    var updateHotKey: ((Bool) -> Void)?
    var session: EngineSession!
    private let searchService: SearchService
    private var currentGeneration = 0
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var hasStarted = false

    init(databasePath: String) {
        self.databasePath = databasePath
        searchService = SearchService(databasePath: databasePath)
        monitoring = UserDefaults.standard.object(forKey: "monitoringEnabled") as? Bool ?? true
        hotKeyEnabled = UserDefaults.standard.object(forKey: "hotKeyEnabled") as? Bool ?? true
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        session = EngineSession(databasePath: databasePath) { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.apply(snapshot) }
        }
        refreshLoginStatus()
        submit(.refresh)
    }

    func apply(_ snapshot: EngineSnapshot) {
        guard snapshot.generation == currentGeneration else { return }
        roots = snapshot.roots
        statistics = snapshot.statistics
        activity = snapshot.activity
        isBusy = snapshot.isBusy
        isWatching = snapshot.isWatching
        if let error = snapshot.error { errorMessage = error }
        if let scopeID, !roots.contains(where: { $0.id == scopeID }) { self.scopeID = nil }
        if let path = snapshot.removedPath {
            // A committed removal is visible before the watcher finishes validating roots.
            // scheduleSearch invalidates any response started before this publication.
            hits.removeAll { $0.id == path || $0.id.hasPrefix(path + "/") }
            if !hits.contains(where: { $0.id == selection }) { selection = hits.first?.id }
            scheduleSearch()
        } else if !snapshot.isBusy { scheduleSearch() }
    }

    func submit(_ command: EngineCommand) {
        searchGeneration += 1
        searchTask?.cancel()
        isSearching = false
        isBusy = true
        searchError = nil
        errorMessage = nil
        currentGeneration = session.submit(command, monitoring: monitoring)
    }

    func toggleMonitoring() {
        monitoring.toggle()
        UserDefaults.standard.set(monitoring, forKey: "monitoringEnabled")
        submit(.refresh)
    }

    private var canRetryMonitoring: Bool { monitoring && !isWatching && !isBusy && !roots.isEmpty }
    var monitoringActionTitle: String { canRetryMonitoring ? "重试自动更新" : (monitoring ? "暂停自动更新" : "继续自动更新") }
    func performMonitoringAction() {
        if canRetryMonitoring { submit(.refresh) }
        else { toggleMonitoring() }
    }

    func scheduleSearch(resetLimit: Bool = false) {
        if resetLimit { resultLimit = 100 }
        searchGeneration += 1
        let revision = searchGeneration
        searchTask?.cancel()
        isSearching = true
        searchError = nil
        let options = SearchOptions(query: query, directory: roots.first(where: { $0.id == scopeID })?.path,
                                    extensions: extensionFilter.split(separator: ",").map {
                                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }.filter { !$0.isEmpty }, kind: kind, limit: resultLimit,
                                    sort: searchSortField, direction: sortOrder.first?.order == .reverse ? .descending : .ascending)
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                let response = try await searchService.search(options)
                guard !Task.isCancelled, revision == searchGeneration else { return }
                hits = response.files.map(SearchHit.init)
                if !hits.contains(where: { $0.id == selection }) { selection = hits.first?.id }
                milliseconds = response.milliseconds
                isSearching = false
            } catch {
                guard !Task.isCancelled, let self, revision == searchGeneration else { return }
                isSearching = false
                hits = []
                selection = nil
                searchError = error.localizedDescription
            }
        }
    }

    var selected: FileRecord? { hits.first(where: { $0.id == selection })?.file }
    private var searchSortField: SearchSortField {
        guard let keyPath = sortOrder.first?.keyPath else { return .relevance }
        switch keyPath {
        case \SearchHit.sortName: return .name
        case \SearchHit.sortDirectory: return .parentPath
        case \SearchHit.sortModified: return .modifiedAt
        case \SearchHit.sortSize: return .size
        default: return .relevance
        }
    }
    var unhealthyRoots: [IndexRoot] { roots.filter { ["error", "unavailable", "interrupted"].contains($0.status) } }

    func chooseDirectories() {
        let panel = NSOpenPanel()
        panel.title = "添加索引目录"
        panel.prompt = "添加目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            Task { @MainActor in self?.submit(.add(paths)) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func openSelection() {
        guard !isSearching, let file = selected else { return }
        guard verifyFile(file) else { return }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) {
            errorMessage = "无法打开“\(file.name)”，请检查默认打开应用和文件权限。"
        }
    }

    func revealSelection() {
        guard !isSearching, let file = selected, verifyFile(file) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }

    func copySelection() {
        guard !isSearching, let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.path, forType: .string)
    }

    func copySelectionName() {
        guard !isSearching, let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.name, forType: .string)
    }

    func requestTrash() {
        guard !isSearching, !isBusy, let file = selected else { return }
        do { pendingTrash = try TrashRequest(path: file.path) }
        catch { errorMessage = error.localizedDescription }
    }

    func confirmTrash() {
        guard let request = pendingTrash else { return }
        pendingTrash = nil
        submit(.trash(request))
    }

    private func verifyFile(_ file: FileRecord) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path), FileManager.default.isReadableFile(atPath: file.path) else {
            errorMessage = "文件已不可用或没有读取权限：\(file.path)\n请确认目录权限和磁盘连接，或刷新索引。"
            scheduleSearch()
            return false
        }
        return true
    }

    func focusSearch() { NotificationCenter.default.post(name: .focusMacSearch, object: nil) }

    func setHotKey(_ enabled: Bool) {
        hotKeyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "hotKeyEnabled")
        updateHotKey?(enabled)
    }

    func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginEnabled = true; loginMessage = "登录后自动运行并在菜单栏保持索引更新"
        case .requiresApproval: loginEnabled = true; loginMessage = "需要在系统设置的登录项中允许 MacSearch"
        case .notRegistered: loginEnabled = false; loginMessage = "关闭"
        case .notFound: loginEnabled = false; loginMessage = "请先将 MacSearch.app 安装到应用程序目录"
        @unknown default: loginMessage = "无法读取登录项状态"
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        loginBusy = true
        Task {
            defer { loginBusy = false; refreshLoginStatus() }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { errorMessage = "无法修改登录启动：\(error.localizedDescription)" }
        }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func shutdown(completion: @escaping @Sendable () -> Void) {
        searchTask?.cancel()
        session?.shutdown(completion: completion)
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "ready": "已就绪"
        case "pending": "等待索引"
        case "scanning": "扫描中"
        case "reconciling": "更新中"
        case "unavailable": "目录不可用"
        case "interrupted": "等待恢复"
        case "error": "访问或索引异常"
        default: status
        }
    }
}

extension Notification.Name {
    static let focusMacSearch = Notification.Name("com.macsearch.focus-search")
}
