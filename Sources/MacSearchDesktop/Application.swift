import AppKit
@preconcurrency import QuickLookUI
import SwiftUI
import MacSearchCore

@main
@MainActor
enum MacSearchDesktopApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

private final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL) {
        previewItemURL = url
        previewItemTitle = url.lastPathComponent
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var model: DesktopModel!
    private let hotKey = GlobalHotKey()
    private var keyMonitor: Any?
    private var selectionObserver: NSObjectProtocol?
    private var previewItems: [QuickLookPreviewItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.macsearch.desktop")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        var databasePath = MacSearchCore.IndexStore.defaultDatabasePath
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--database"), index + 1 < args.count { databasePath = args[index + 1] }
        model = DesktopModel(databasePath: databasePath)
        model.toggleWindow = { [weak self] in self?.toggleWindow() }
        model.hideWindow = { [weak self] in self?.window.orderOut(nil) }
        model.updateHotKey = { [weak self] enabled in self?.setHotKey(enabled) }
        NSApp.setActivationPolicy(.regular)
        configureMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 670),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "MacSearch"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 850, height: 570)
        window.setFrameAutosaveName("MacSearchMainWindow")
        window.contentView = NSHostingView(rootView: SearchView(model: model))
        window.center()
        configureStatusItem()
        configureKeyMonitor()
        selectionObserver = NotificationCenter.default.addObserver(forName: .selectionChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
                self.previewItems = self.model.previewURLForSelection().map { [QuickLookPreviewItem(url: $0)] } ?? []
                panel.reloadData()
            }
        }
        setHotKey(model.hotKeyEnabled)
        model.start()
        showWindow()
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 MacSearch", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 MacSearch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 MacSearch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"),
                                      ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        let files = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "搜索文件", action: #selector(focusSearch), keyEquivalent: "f")
        fileMenu.addItem(withTitle: "添加索引目录…", action: #selector(addDirectory), keyEquivalent: "o")
        let reveal = fileMenu.addItem(withTitle: "在 Finder 中显示", action: #selector(revealSelection), keyEquivalent: "\r")
        reveal.keyEquivalentModifierMask = [.command]
        let copy = fileMenu.addItem(withTitle: "复制文件路径", action: #selector(copyPath), keyEquivalent: "C")
        copy.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "移到废纸篓…", action: #selector(trashSelection), keyEquivalent: "\u{8}")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(closeWindow), keyEquivalent: "w")
        files.submenu = fileMenu
        menu.addItem(files)
        for submenu in [appMenu, fileMenu] {
            for item in submenu.items where item.action != #selector(NSApplication.terminate(_:)) && item.action != #selector(NSApplication.hide(_:)) {
                item.target = self
            }
        }
        NSApp.mainMenu = menu
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "MacSearch")
        statusItem.button?.toolTip = "MacSearch · 本地文件搜索"
        let menu = NSMenu()
        menu.addItem(withTitle: "打开搜索窗口", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "暂停 / 继续自动更新", action: #selector(toggleMonitoring), keyEquivalent: "")
        menu.addItem(withTitle: "管理索引目录…", action: #selector(showDirectories), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MacSearch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    private func configureKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, NSApp.keyWindow == self.window, self.window.attachedSheet == nil else { return false }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if event.keyCode == 36 && modifiers.isEmpty && !self.model.isSearching {
                    self.model.openSelection()
                    return true
                }
                if event.keyCode == 125 && modifiers.isEmpty && self.window.firstResponder is NSTextView,
                   let table = self.findTable(in: self.window.contentView), !self.model.hits.isEmpty {
                    self.model.selection = self.model.selection ?? self.model.hits.first?.id
                    self.window.makeFirstResponder(table)
                    return true
                }
                if event.keyCode == 49 && modifiers.isEmpty,
                   let table = self.findTable(in: self.window.contentView), self.window.firstResponder === table,
                   self.model.selected != nil, !self.model.isSearching {
                    self.toggleQuickLook()
                    return true
                }
                if event.keyCode == 8 && modifiers == [.command],
                   let table = self.findTable(in: self.window.contentView), self.window.firstResponder === table,
                   self.model.selected != nil, !self.model.isSearching {
                    self.model.copySelectionFile()
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable(in: $0) }.first
    }

    private func setHotKey(_ enabled: Bool) {
        hotKey.unregister()
        model.hotKeyError = nil
        guard enabled else { return }
        hotKey.onPressed = { [weak self] in self?.toggleWindow() }
        do { try hotKey.register() }
        catch { model.hotKeyError = error.localizedDescription }
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard let url = model.previewURLForSelection() else { return }
        previewItems = [QuickLookPreviewItem(url: url)]
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems[index]
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.focusSearch()
    }
    private func toggleWindow() {
        if window.isVisible && NSApp.isActive { window.orderOut(nil) }
        else { showWindow() }
    }
    @objc private func focusSearch() { showWindow(); model.focusSearch() }
    @objc private func closeWindow() { window.performClose(nil) }
    @objc private func showSettings() { showWindow(); model.showSettings = true }
    @objc private func showDirectories() { showWindow(); model.showDirectories = true }
    @objc private func toggleMonitoring() { model.toggleMonitoring() }
    @objc private func addDirectory() { showWindow(); model.chooseDirectories() }
    @objc private func revealSelection() { model.revealSelection() }
    @objc private func copyPath() { model.copySelection() }
    @objc private func trashSelection() { model.requestTrash() }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "MacSearch", .applicationVersion: "1.2.0",
                                                     .credits: NSAttributedString(string: "完全离线的 macOS 原生文件搜索")])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        hotKey.unregister()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let panel = QLPreviewPanel.shared(), panel.isVisible { panel.orderOut(nil) }
        model.shutdown { Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}
