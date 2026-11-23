import SwiftUI

// A civil day is independent of the time zone in which the task was created.
struct Day: Codable, Comparable, Hashable, Identifiable {
    let ordinal: Int
    var id: Int { ordinal }
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    static var local: Calendar { Calendar(identifier: .gregorian) }
    init(_ date: Date) {
        let parts = Self.local.dateComponents([.year, .month, .day], from: date)
        ordinal = Int((Self.utc.date(from: parts)!.timeIntervalSince1970 / 86400).rounded())
    }
    private init(ordinal: Int) { self.ordinal = ordinal }
    var date: Date {
        var parts = Self.utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ordinal) * 86400))
        parts.hour = 12
        return Self.local.date(from: parts)!
    }
    var number: Int { Self.local.component(.day, from: date) }
    var weekday: Int { (Self.local.component(.weekday, from: date) + 5) % 7 }
    var weekStart: Day { adding(-weekday) }
    var monthStart: Day { adding(1 - number) }
    var monthLength: Int { Self.local.range(of: .day, in: .month, for: date)!.count }
    func adding(_ days: Int) -> Day { Day(ordinal: ordinal + days) }
    func months(_ count: Int) -> Day { Day(Self.local.date(byAdding: .month, value: count, to: date)!) }
    func label(_ format: String) -> String {
        DayFormat.string(date, format: format)
    }
    static func < (lhs: Day, rhs: Day) -> Bool { lhs.ordinal < rhs.ordinal }
}

private enum DayFormat {
    static func string(_ date: Date, format: String) -> String {
        let key = "DeskCalendar.format." + format
        let cache = Thread.current.threadDictionary
        if let existing = cache[key] as? DateFormatter { return existing.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Day.local
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        cache[key] = formatter
        return formatter.string(from: date)
    }
}

enum Priority: Int, Codable, CaseIterable, Identifiable {
    case low, medium, high
    var id: Self { self }
    var label: String { ["低", "中", "高"][rawValue] }
    var color: Color { [.mint, .orange, .pink][rawValue] }
}

struct CalendarTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    var start: Day
    var end: Day
    var due: Day
    var priority: Priority = .medium
    var reminderMinute: Int?
    var checked = Set<Day>()

    init(on day: Day) { start = day; end = day; due = day }
    var total: Int { end.ordinal - start.ordinal + 1 }
    var finished: Bool { checked.count == total }
    func covers(_ day: Day) -> Bool { start <= day && day <= end }
    var reminderDate: Date? {
        guard let minute = reminderMinute, !finished else { return nil }
        return Day.local.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: due.date)
    }
}

enum CalendarFailure: LocalizedError {
    case invalid, unreadable
    var errorDescription: String? {
        switch self {
        case .invalid: return "请填写任务标题，并确认结束日期不早于开始日期。"
        case .unreadable: return "任务文件无法读取。为保护原数据，已暂停保存。"
        }
    }
}

final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [CalendarTask] = []
    @Published var errorMessage: String?
    private let file: URL
    private var writable = true
    var didSave: (() -> Void)?

    init(file: URL) {
        self.file = file
        do {
            let data = try Data(contentsOf: file)
            tasks = try JSONDecoder().decode([CalendarTask].self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // First launch.
        } catch {
            writable = false
            errorMessage = CalendarFailure.unreadable.localizedDescription
        }
    }
    func on(_ day: Day) -> [CalendarTask] {
        tasks.filter { $0.covers(day) }.sorted {
            let a = $0.checked.contains(day), b = $1.checked.contains(day)
            if a != b { return !a }
            if $0.priority != $1.priority { return $0.priority.rawValue > $1.priority.rawValue }
            if $0.due != $1.due { return $0.due < $1.due }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    func save(_ draft: CalendarTask) throws {
        guard writable else { throw CalendarFailure.unreadable }
        var task = draft
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.title.isEmpty, task.start <= task.end else { throw CalendarFailure.invalid }
        var next = tasks
        if let index = next.firstIndex(where: { $0.id == task.id }) {
            task.checked = next[index].checked.filter { task.covers($0) }
            next[index] = task
        } else { next.append(task) }
        try persist(next)
    }
    func toggle(_ id: UUID, on day: Day) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].covers(day) else { return }
        var next = tasks
        if next[index].checked.contains(day) { next[index].checked.remove(day) }
        else { next[index].checked.insert(day) }
        do { try persist(next) } catch { errorMessage = error.localizedDescription }
    }
    func delete(_ id: UUID) throws { try persist(tasks.filter { $0.id != id }) }
    private func persist(_ next: [CalendarTask]) throws {
        guard writable else { throw CalendarFailure.unreadable }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        tasks = next
        didSave?()
    }
}

enum CalendarMode: String, CaseIterable { case day = "日", week = "周", month = "月" }

enum Placement: String, CaseIterable {
    case full = "整个桌面", left = "左半屏", right = "右半屏"
    case upperLeft = "左上角", upperRight = "右上角", lowerLeft = "左下角", lowerRight = "右下角"
    func frame(in area: CGRect) -> CGRect {
        let half = area.width / 2, height = area.height / 2
        switch self {
        case .full: return area
        case .left: return CGRect(x: area.minX, y: area.minY, width: half, height: area.height)
        case .right: return CGRect(x: area.midX, y: area.minY, width: half, height: area.height)
        default:
            let left = self == .upperLeft || self == .lowerLeft
            let upper = self == .upperLeft || self == .upperRight
            return CGRect(x: left ? area.minX : area.midX, y: upper ? area.midY : area.minY, width: half, height: height)
        }
    }
}
