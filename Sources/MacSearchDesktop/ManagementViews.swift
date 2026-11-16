import AppKit
import SwiftUI
import MacSearchCore

struct DirectoryManagerView: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: IndexRoot?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("索引目录").font(.title2.weight(.semibold))
                    Text("管理搜索范围，查看索引进度与访问状态。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.roots.isEmpty {
                Text("尚未添加索引目录").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 170)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.roots, id: \.id) { root in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label((root.path as NSString).lastPathComponent, systemImage: "folder").font(.headline)
                                    Spacer()
                                    Text(DesktopModel.statusLabel(root.status)).font(.caption).foregroundStyle(root.status == "ready" ? Color.secondary : .orange)
                                }
                                Text(root.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                HStack {
                                    Text("\(root.entryCount.formatted()) 项")
                                    if let timestamp = root.lastScanAt {
                                        Text("最近更新：" + Date(timeIntervalSince1970: Double(timestamp)).formatted(date: .abbreviated, time: .shortened))
                                    }
                                    Spacer()
                                }.font(.caption).foregroundStyle(.secondary)
                                if let error = root.lastError {
                                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                                }
                                HStack {
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root.path)]) }
                                    Spacer()
                                    Button("重建索引") { model.submit(.rebuild(root.id)) }.disabled(model.isBusy)
                                    Button("移除", role: .destructive) { pendingRemoval = root }.disabled(model.isBusy)
                                }.controlSize(.small)
                            }.padding(15).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.frame(maxHeight: 380)
            }
            HStack {
                Button { model.chooseDirectories() } label: { Label("添加目录", systemImage: "folder.badge.plus") }
                Spacer()
                Button("重建全部索引") { model.submit(.rebuild(nil)) }.disabled(model.roots.isEmpty)
            }.disabled(model.isBusy)
            if model.isBusy { HStack { ProgressView().controlSize(.small); Text(model.activity).font(.caption).foregroundStyle(.secondary) } }
        }
        .padding(24).frame(width: 620)
        .alert("移除索引目录？", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移除索引", role: .destructive) {
                if let root = pendingRemoval { model.submit(.remove(root.id)) }
                pendingRemoval = nil
            }
        } message: { Text("目录中的磁盘文件保留，仅移除搜索索引记录。") }
    }
}

struct SettingsView: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            GroupBox("启动与快捷键") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("登录时启动 MacSearch", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))
                        .disabled(model.loginBusy)
                    Text(model.loginMessage).font(.caption).foregroundStyle(.secondary)
                    Button("打开系统登录项设置") { model.openLoginSettings() }.font(.caption)
                    Divider()
                    Toggle("启用全局快捷键 ⌃⌥空格", isOn: Binding(get: { model.hotKeyEnabled }, set: model.setHotKey))
                    Text("随时显示或隐藏搜索窗口，无需辅助功能权限。").font(.caption).foregroundStyle(.secondary)
                    if let error = model.hotKeyError { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("索引与运行") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("自动监听文件变化", isOn: Binding(get: { model.monitoring }, set: { _ in model.toggleMonitoring() }))
                    Text("关闭窗口后继续在菜单栏运行；从菜单栏退出后停止索引。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("索引数据库").font(.caption.weight(.medium))
                    Text(model.databasePath).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    if let stats = model.statistics {
                        Text("\(stats.entryCount.formatted()) 项 · \(ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("与命令行共享索引。若 CLI 正在维护索引，搜索仍可使用；停止 CLI 监听后可在应用中重新开启自动更新。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.padding(24).frame(width: 530)
        .onAppear { model.refreshLoginStatus() }
    }
}
