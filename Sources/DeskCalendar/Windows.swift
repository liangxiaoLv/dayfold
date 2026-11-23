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

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    func start() {
        let panel = DesktopPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "桌面待办日历"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        board = panel
        panel.contentView = host(BoardView(space: self, store: store))
        position()
        applyLevel()
        if store.errorMessage == nil { reminders.synchronize(store.tasks) }
    }
    func refreshDay() {
        let new = Day(Date())
        if anchor == today { anchor = new }
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
        board?.orderFrontRegardless()
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
    func openOverview() {
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
        app.addItem(withTitle: "退出桌面待办日历", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
    @objc private func showOverview() { space.openOverview() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        space.openOverview()
        return false
    }
}
