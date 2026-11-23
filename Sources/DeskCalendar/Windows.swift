import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var previous: Task<Void, Never>?
    var report: (String) -> Void = { _ in }
    override init() {
        super.init()
        center.delegate = self
    }
    func authorize() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func synchronize(_ tasks: [CalendarTask]) {
        let earlier = previous
        previous = Task {
            await earlier?.value
            let pending = await center.pendingNotificationRequests()
            let active = tasks.filter { ($0.reminderDate ?? .distantPast) > Date() }
            let ids = Set(active.map { $0.id.uuidString })
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { !ids.contains($0) })
            for item in active {
                guard let when = item.reminderDate else { continue }
                let components = Day.local.dateComponents([.year, .month, .day, .hour, .minute], from: when)
                if let old = pending.first(where: { $0.identifier == item.id.uuidString }),
                   old.content.body == item.title,
                   (old.trigger as? UNCalendarNotificationTrigger)?.dateComponents == components { continue }
                let content = UNMutableNotificationContent()
                content.title = "待办到期提醒"
                content.body = item.title
                content.sound = .default
                let request = UNNotificationRequest(identifier: item.id.uuidString, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                do { try await center.add(request) }
                catch { report("提醒未能安排：" + error.localizedDescription) }
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

let compactBarFrameName: NSWindow.FrameAutosaveName = "CompactBar"

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct RestartLayout: Codable {
    let anchor: Date
    let board: CGRect
    let bar: CGRect?
    let overview: CGRect?
    static let flag = "--dayfold-layout="
    var argument: String {
        get throws { try Self.flag + JSONEncoder().encode(self).base64EncodedString() }
    }
    static func fromArguments() -> Self? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix(flag) }),
              let data = Data(base64Encoded: String(arg.dropFirst(flag.count))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

@MainActor
final class Workspace: ObservableObject {
    let store: TaskStore
    let reminders = Reminders()
    private let defaults = UserDefaults.standard
    @Published var mode: CalendarMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var placement: Placement { didSet { defaults.set(placement.rawValue, forKey: "placement"); position(animated: true) } }
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "pinned"); applyLevel() } }
    @Published var anchor = Day(Date())
    @Published var today = Day(Date())
    private var board: NSPanel?
    private var compactBar: NSPanel?
    private let updates = Updates()
    private(set) var restarting = false
    private var updateWindow: NSWindow?
    private var overview: NSWindow?
    private var editor: NSWindow?
    init() {
        mode = CalendarMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .week
        placement = Placement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .right
        pinned = defaults.bool(forKey: "pinned")
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = TaskStore(file: folder.appendingPathComponent("DeskCalendar/tasks.json"))
        reminders.report = { [weak self] text in self?.store.errorMessage = text }
        store.didSave = { [weak self] in
            guard let self else { return }
            self.reminders.synchronize(self.store.tasks)
        }
    }
    private func desktopPanel() -> NSPanel {
        let panel = DesktopPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "折历"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }
    func start() {
        let panel = desktopPanel()
        board = panel
        panel.contentView = host(BoardView(space: self, store: store))
        position()
        applyLevel()
        if let layout = RestartLayout.fromArguments() {
            anchor = Day(layout.anchor)
            restore(board, frame: layout.board)
            if let frame = layout.bar { collapse(); restore(compactBar, frame: frame) }
            if let frame = layout.overview { openOverview(); restore(overview, frame: frame) }
        }
        if store.errorMessage == nil { reminders.synchronize(store.tasks) }
    }
    private func restore(_ window: NSWindow?, frame: CGRect) {
        if frame.width > 0, frame.height > 0, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window?.setFrame(frame, display: true)
        }
    }

    func requireSavedEditor() throws {
        if editor?.isVisible == true {
            editor?.makeKeyAndOrderFront(nil)
            throw ReplacementError("请先保存或关闭正在编辑的待办，再更新折历。")
        }
    }

    func restart(with replacement: AppReplacement) async throws {
        let arguments: [String]
        do {
            try requireSavedEditor()
            let others = NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                $0.bundleURL?.resolvingSymlinksInPath().path == replacement.installed.resolvingSymlinksInPath().path
            }
            guard others.isEmpty else { throw ReplacementError("请先关闭从同一位置启动的另一份折历，再重试。") }
            guard let board else { throw ReplacementError("日历窗口尚未就绪，请重试。") }
            let layout = RestartLayout(anchor: anchor.date, board: board.frame, bar: compactBar?.frame,
                                       overview: overview?.isVisible == true ? overview?.frame : nil)
            arguments = [try layout.argument]
        } catch { replacement.discard(); throw error }

        let visibleWindows = [board, compactBar, overview].compactMap { $0 }.filter { $0.isVisible }
        restarting = true
        visibleWindows.forEach { $0.orderOut(nil) }
        defaults.synchronize()
        do {
            try await replacement.restart(arguments: arguments)
            restarting = false
            NSApp.terminate(nil)
        } catch {
            restarting = false
            visibleWindows.forEach { $0.orderFrontRegardless() }
            throw error
        }
    }
    func collapse() {
        guard let board, compactBar == nil else { return }
        let bar = desktopPanel()
        bar.title = "折历窄栏"
        bar.isMovable = true
        bar.level = board.level
        bar.contentView = host(CompactBar(expand: { [weak self] in self?.expand() }))
        let size = NSSize(width: 176, height: 38)
        let frame = NSRect(x: board.frame.maxX - size.width, y: board.frame.maxY - size.height,
                           width: size.width, height: size.height)
        bar.setFrame(frame, display: false)
        if bar.setFrameUsingName(compactBarFrameName, force: true),
           !NSScreen.screens.contains(where: { $0.visibleFrame.contains(bar.frame) }) {
            // The saved location may belong to a disconnected display.
            bar.setFrame(frame, display: false)
        }
        compactBar = bar
        board.orderOut(nil)
        bar.orderFrontRegardless()
    }
    func expand() {
        guard let bar = compactBar else { return }
        bar.orderOut(nil)
        compactBar = nil
        board?.orderFrontRegardless()
    }
    func refreshDay() {
        let new = Day(Date())
        if compactBar == nil && anchor == today { anchor = new }
        today = new
    }
    func position(animated: Bool = false) {
        guard let screen = board?.screen ?? NSScreen.main else { return }
        let frame = placement.frame(in: screen.visibleFrame).insetBy(dx: 6, dy: 6)
        board?.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func applyLevel() {
        let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        overview?.level = pinned ? .floating : .normal
        board?.level = pinned ? .floating : desktop
        compactBar?.level = board?.level ?? desktop
        (compactBar ?? board)?.orderFrontRegardless()
    }
    private func host<V: View>(_ view: V) -> NSHostingView<some View> {
        let hosted = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")))
        hosted.sizingOptions = []
        return hosted
    }
    private func window(title: String, size: CGSize, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
    func checkForUpdates() {
        if updateWindow == nil {
            let win = window(title: "检查更新", size: CGSize(width: 380, height: 225), resizable: false)
            win.contentView = host(UpdateView(updates: updates, space: self))
            updateWindow = win
        }
        if updateWindow?.isVisible != true { updates.check() }
        updateWindow?.level = pinned ? .floating : .normal
        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func openOverview() {
        guard !restarting else { return }
        if overview == nil {
            let win = window(title: "任务总览", size: CGSize(width: 660, height: 500), resizable: true)
            win.minSize = CGSize(width: 450, height: 320)
            win.contentView = host(Overview(space: self, store: store))
            overview = win
        }
        overview?.level = pinned ? .floating : .normal
        overview?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func edit(_ item: CalendarTask) {
        guard !restarting else { return }
        if let editor, editor.isVisible {
            editor.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = window(title: store.tasks.contains { $0.id == item.id } ? "编辑待办" : "新增待办",
                         size: CGSize(width: 398, height: 480), resizable: false)
        win.level = .floating
        win.contentView = host(TaskEditor(space: self, item: item, close: { [weak win] in win?.close() }))
        editor = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func step(_ offset: Int) {
        switch mode {
        case .day: anchor = anchor.adding(offset)
        case .week: anchor = anchor.adding(offset * 7)
        case .month: anchor = anchor.monthStart.months(offset)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var space: Workspace!
    func applicationDidFinishLaunching(_ notification: Notification) {
        space = Workspace()
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "任务总览", action: #selector(showOverview), keyEquivalent: "0").target = self
        app.addItem(withTitle: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        app.addItem(withTitle: "退出折历", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        menu.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        for (label, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: label, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        space.start()
        NotificationCenter.default.addObserver(self, selector: #selector(position), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .NSCalendarDayChanged, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func position() { space.position() }
    @objc private func refresh() { space.refreshDay() }
    @objc private func checkUpdates() { space.checkForUpdates() }
    @objc private func showOverview() { space.openOverview() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        space?.restarting == true ? .terminateCancel : .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        space.openOverview()
        return false
    }
}
