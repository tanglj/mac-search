import AppKit
import SwiftUI
import MacSearchCore

private let accent = Color(red: 0.13, green: 0.44, blue: 0.33)

@MainActor
private final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 2048 }

    func image(for path: String) -> NSImage {
        let key = path as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct ExtensionGroup: Identifiable {
    let title: String
    let extensions: [String]
    var id: String { title }
}

private let commonExtensionGroups = [
    ExtensionGroup(title: "Office", extensions: ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "odt", "ods", "odp"]),
    ExtensionGroup(title: "PDF", extensions: ["pdf"]),
    ExtensionGroup(title: "音频", extensions: ["mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff"]),
    ExtensionGroup(title: "视频", extensions: ["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv"]),
    ExtensionGroup(title: "JSON", extensions: ["json", "jsonl"]),
    ExtensionGroup(title: "Markdown", extensions: ["md", "markdown", "mdown", "mkd"]),
    ExtensionGroup(title: "图片", extensions: ["jpg", "jpeg", "png", "gif", "webp", "svg", "heic", "tif", "tiff", "bmp"]),
    ExtensionGroup(title: "压缩包", extensions: ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"])
]

struct SearchView: View {
    @ObservedObject var model: DesktopModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                searchHeader
                Divider()
                filterBar
                Divider()
                results
                Divider()
                footer
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(accent)
        .frame(minWidth: 850, minHeight: 540)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusMacSearch)) { _ in searchFocused = true }
        .onChange(of: model.query) { _ in model.scheduleSearch(resetLimit: true) }
        .onChange(of: model.extensionFilter) { _ in model.scheduleSearch(resetLimit: true) }
        .onChange(of: model.kind) { _ in model.scheduleSearch(resetLimit: true) }
        .onChange(of: model.scopeID) { _ in model.scheduleSearch(resetLimit: true) }
        .onChange(of: model.sortOrder) { _ in model.scheduleSearch(resetLimit: true) }
        .onChange(of: model.selection) { _ in NotificationCenter.default.post(name: .selectionChanged, object: nil) }
        .onExitCommand { model.hideWindow?() }
        .sheet(isPresented: $model.showDirectories) { DirectoryManagerView(model: model) }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .alert("移除索引目录？", isPresented: Binding(get: { model.rootToRemove != nil }, set: { if !$0 { model.rootToRemove = nil } })) {
            Button("取消", role: .cancel) { model.rootToRemove = nil }
            Button("移除索引", role: .destructive) {
                if let root = model.rootToRemove { model.submit(.remove(root.id)) }
                model.rootToRemove = nil
            }
        } message: { Text("移除该目录的索引记录，磁盘文件保留。") }
        .alert("移到废纸篓？", isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } })) {
            Button("取消", role: .cancel) { model.pendingTrash = nil }
            Button("移到废纸篓", role: .destructive) { model.confirmTrash() }
        } message: {
            Text("将以下文件或目录移到系统废纸篓；目录内的所有文件也会一起移动，可在 Finder 的废纸篓中恢复。\n\n\(model.pendingTrash?.path ?? "")")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(accent, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacSearch").font(.system(size: 17, weight: .semibold))
                    Text("本地文件搜索").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(20).padding(.bottom, 15)
            Text("搜索范围").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 20)
            scopeButton(id: nil, title: "全部文件", subtitle: "\(model.statistics?.entryCount.formatted() ?? "0") 个索引条目", symbol: "square.stack.3d.up")
                .padding(.horizontal, 10).padding(.top, 8)
            HStack {
                Text("索引目录").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.showDirectories = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).help("管理索引目录").accessibilityLabel("管理索引目录")
            }.padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.roots, id: \.id) { root in
                        scopeButton(id: root.id, title: (root.path as NSString).lastPathComponent,
                                    subtitle: "\(root.entryCount.formatted()) 项 · \(DesktopModel.statusLabel(root.status))", symbol: "folder")
                            .help(root.path)
                            .contextMenu {
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root.path)]) }
                                Button("重建此目录") { model.submit(.rebuild(root.id)) }.disabled(model.isBusy)
                                Divider()
                                Button("移除索引", role: .destructive) { model.rootToRemove = root }.disabled(model.isBusy)
                            }
                    }
                }.padding(.horizontal, 10)
            }
            Button { model.chooseDirectories() } label: {
                Label("添加目录", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }.buttonStyle(.plain).disabled(model.isBusy).padding(.horizontal, 10).padding(.vertical, 8)
                .accessibilityIdentifier("add-directory")
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    else { Circle().fill(model.isWatching ? accent : .orange).frame(width: 6, height: 6) }
                    Text(model.activity).font(.system(size: 11, weight: .medium)).lineLimit(2)
                }
                HStack {
                    Button(model.monitoringActionTitle) { model.performMonitoringAction() }
                        .buttonStyle(.link).font(.system(size: 11))
                    Spacer()
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("设置").accessibilityLabel("设置")
                }
                Text("⌃⌥空格  唤起搜索").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(18)
        }
        .background(.regularMaterial)
    }

    private func scopeButton(id: Int64?, title: String, subtitle: String, symbol: String) -> some View {
        Button { model.scopeID = id } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(model.scopeID == id ? accent : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.isEmpty ? "/" : title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(10).contentShape(Rectangle())
                .background(model.scopeID == id ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var searchHeader: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass").font(.system(size: 21, weight: .regular)).foregroundStyle(accent)
            TextField("搜索文件名…", text: $model.query)
                .font(.system(size: 24, weight: .regular)).textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { if !model.isSearching { model.openSelection() } }
                .accessibilityLabel("搜索文件名").accessibilityIdentifier("search-field")
            if model.isSearching { ProgressView().controlSize(.small) }
            if !model.query.isEmpty {
                Button { model.query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
            Text("⌘F").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 26).padding(.vertical, 25)
    }

    private var filterBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("类型", selection: $model.kind) {
                    Text("全部类型").tag(EntryKind.all)
                    Text("文件").tag(EntryKind.file)
                    Text("目录").tag(EntryKind.directory)
                }.labelsHidden().frame(width: 110).accessibilityLabel("文件类型筛选")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(commonExtensionGroups) { group in
                            extensionChip(group)
                        }
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity)
                .layoutPriority(0)
                .accessibilityLabel("常用扩展名")
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("扩展名，如 pdf,docx", text: $model.extensionFilter).textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("扩展名筛选")
                }
                .frame(minWidth: 180, idealWidth: 260)
                .layoutPriority(1)
                Spacer()
                if !model.sortOrder.isEmpty {
                    Button("恢复匹配度") { model.sortOrder = [] }
                        .buttonStyle(.link).font(.system(size: 11)).help("恢复默认匹配度排序")
                }
                Button { model.scheduleSearch() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新搜索结果").accessibilityLabel("刷新搜索结果")
            }.padding(.horizontal, 22).padding(.vertical, 11)
            if let message = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.padding(12).background(Color.orange.opacity(0.08))
            } else if !model.unhealthyRoots.isEmpty {
                HStack {
                    Label("\(model.unhealthyRoots.count) 个目录需要检查，已有结果可能过期", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("查看目录") { model.showDirectories = true }
                }.font(.system(size: 11)).padding(12).background(Color.orange.opacity(0.08))
            }
        }
    }

    private func extensionChip(_ group: ExtensionGroup) -> some View {
        let allSelected = model.hasAllExtensionFilters(group.extensions)
        let partiallySelected = !allSelected && model.hasAnyExtensionFilter(group.extensions)
        let symbol = allSelected ? "checkmark.square.fill" : (partiallySelected ? "minus.square.fill" : "square")
        return Button {
            model.toggleExtensionFilters(group.extensions)
        } label: {
            Label(group.title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(allSelected || partiallySelected ? accent : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background((allSelected || partiallySelected ? accent : Color.secondary).opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(group.extensions.map { ".\($0)" }.joined(separator: ", "))
        .accessibilityLabel(group.title)
        .accessibilityValue(allSelected ? "已选择" : (partiallySelected ? "部分选择" : "未选择"))
    }

    @ViewBuilder private var results: some View {
        if model.roots.isEmpty && !model.isBusy {
            emptyState(symbol: "folder.badge.plus", title: "先选一个目录", detail: "添加你希望搜索的文件夹。索引完成后，输入文件名即可找到。") {
                Button("添加索引目录") { model.chooseDirectories() }.buttonStyle(.borderedProminent)
            }
        } else if let error = model.searchError {
            emptyState(symbol: "exclamationmark.magnifyingglass", title: "暂时无法搜索", detail: error) {
                Button("重试") { model.scheduleSearch() }
            }
        } else if model.hits.isEmpty {
            emptyState(symbol: model.isBusy || model.isSearching ? "magnifyingglass" : "doc.text.magnifyingglass",
                       title: model.isBusy ? "正在建立索引" : (model.isSearching ? "正在搜索" : "没有找到匹配文件"),
                       detail: model.isBusy ? "文件会在索引完成后显示。你可以继续输入关键词。" : "试试更短的关键词，或调整目录与文件类型。") { EmptyView() }
        } else {
            Table(model.hits, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("名称", value: \.sortName) { hit in
                    HStack(spacing: 8) {
                        Image(nsImage: FileIconCache.shared.image(for: hit.file.path)).resizable().frame(width: 20, height: 20)
                        Text(hit.file.name).font(.system(size: 12)).lineLimit(1)
                    }.padding(.vertical, 4)
                }.width(min: 180, ideal: 255)
                TableColumn("所在目录", value: \.sortDirectory) { hit in
                    Text(hit.file.parentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(hit.file.path)
                }.width(min: 150, ideal: 250)
                TableColumn("修改时间", value: \.sortModified) { hit in
                    if let timestamp = hit.file.modifiedAt {
                        Text(Date(timeIntervalSince1970: Double(timestamp)), format: .dateTime.year().month().day())
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.width(95)
                TableColumn("大小", value: \.sortSize) { hit in
                    Text(hit.file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.width(75)
            }
            .contextMenu(forSelectionType: String.self) { paths in
                Button("打开") { model.selection = paths.first; model.openSelection() }.disabled(paths.isEmpty || model.isSearching)
                Button("在 Finder 中显示") { model.selection = paths.first; model.revealSelection() }.disabled(paths.isEmpty)
                Button("复制路径") { model.selection = paths.first; model.copySelection() }.disabled(paths.isEmpty)
                Button("复制名称") { model.selection = paths.first; model.copySelectionName() }
                    .disabled(paths.isEmpty || model.isSearching)
                Divider()
                Button("移到废纸篓…", role: .destructive) { model.selection = paths.first; model.requestTrash() }
                    .disabled(paths.isEmpty || model.isSearching || model.isBusy)
            } primaryAction: { paths in
                model.selection = paths.first
                if !model.isSearching { model.openSelection() }
            }
        }
    }

    private func emptyState<Actions: View>(symbol: String, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 42, weight: .ultraLight)).foregroundStyle(accent.opacity(0.7))
                .frame(width: 80, height: 80).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.system(size: 20, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 350)
            actions().padding(.top, 6)
            Spacer()
            Spacer().frame(height: 15)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(25)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if model.hits.count == model.resultLimit && model.resultLimit < 1000 {
                Button("加载更多结果") { model.resultLimit += 100; model.scheduleSearch() }.buttonStyle(.link).font(.system(size: 11)).padding(8)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isSearching
                         ? "正在更新结果 · 当前显示 \(model.hits.count) 个"
                         : "\(model.hits.count) 个结果 · \(String(format: "%.0f", model.milliseconds)) ms")
                        .font(.system(size: 11, weight: .medium))
                    Text(model.selected?.path ?? "↑↓ 选择结果  ·  空格预览  ·  回车打开  ·  ⌘↩ 在 Finder 中显示")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button { model.requestTrash() } label: { Image(systemName: "trash") }
                    .disabled(model.isBusy).help("移到废纸篓（⌘⌫）").accessibilityLabel("移到废纸篓")
                Button { model.revealSelection() } label: { Image(systemName: "folder") }
                    .help("在 Finder 中显示（⌘↩）").accessibilityLabel("在 Finder 中显示")
                Button("打开") { model.openSelection() }.buttonStyle(.borderedProminent)
            }.disabled(model.selected == nil || model.isSearching).padding(.horizontal, 20).padding(.vertical, 13)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}
