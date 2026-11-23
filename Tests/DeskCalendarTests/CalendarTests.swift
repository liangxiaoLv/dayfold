import Foundation
import Testing
@testable import DeskCalendar

struct CalendarTests {
    let first = Day(Day.local.date(from: DateComponents(year: 2026, month: 11, day: 23))!)
    func withStore(_ run: (TaskStore, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tasks.json")
        try run(TaskStore(file: file), file)
    }
    @Test func testInclusiveRangeSharedEditsAndDailyProgressSurviveRestart() throws {
        try withStore { store, file in
            var task = CalendarTask(on: first)
            task.title = "准备评审"
            task.end = first.adding(3)
            try store.save(task)
            store.toggle(task.id, on: first.adding(1))
            task.title = "更新标题"
            task.priority = .high
            task.due = task.end
            try store.save(task)
            let fresh = TaskStore(file: file)
            #expect(fresh.tasks.count == 1)
            for offset in 0...3 {
                let day = first.adding(offset)
                let entry = try #require(fresh.on(day).first)
                #expect(entry.title == task.title)
                #expect(entry.priority == .high)
                #expect(entry.due == task.end)
                #expect(entry.checked.contains(day) == (offset == 1))
                #expect(entry.total == 4)
            }
            #expect(fresh.on(first.adding(4)).isEmpty)
            for offset in [0, 2, 3] { fresh.toggle(task.id, on: first.adding(offset)) }
            #expect(fresh.tasks[0].finished)
            fresh.toggle(task.id, on: first)
            #expect(!fresh.tasks[0].finished)
        }
    }
    @Test func testShrinkingRangePrunesOnlyRemovedDays() throws {
        try withStore { store, _ in
            var task = CalendarTask(on: first)
            task.title = "任务"
            task.end = first.adding(3)
            try store.save(task)
            store.toggle(task.id, on: first)
            store.toggle(task.id, on: task.end)
            task.start = first.adding(1)
            try store.save(task)
            #expect(store.tasks[0].checked == [task.end])
            #expect(store.tasks[0].total == 3)
        }
    }
    @Test func testDateOnlyDeadlineAndOptInReminder() {
        var task = CalendarTask(on: first)
        #expect(task.reminderDate == nil)
        task.due = first.adding(3)
        task.reminderMinute = 9 * 60 + 15
        #expect(task.reminderDate.map { Day($0) } == task.due)
        #expect(task.reminderDate.map { Day.local.component(.hour, from: $0) } == 9)
        #expect(task.reminderDate.map { Day.local.component(.minute, from: $0) } == 15)
        task.checked = [first]
        #expect(task.reminderDate == nil)
    }
    @Test func testPlacementUsesVisibleScreenOrigin() {
        let screen = CGRect(x: -1200, y: 36, width: 1200, height: 800)
        #expect(Placement.right.frame(in: screen) == CGRect(x: -600, y: 36, width: 600, height: 800))
        #expect(Placement.upperLeft.frame(in: screen) == CGRect(x: -1200, y: 436, width: 600, height: 400))
        #expect(Placement.lowerRight.frame(in: screen).size == CGSize(width: 600, height: 400))
        #expect(Placement.full.frame(in: screen) == screen)
    }
    @Test func testWeekCrossesYearAndLeapMonth() {
        let jan = Day(Day.local.date(from: DateComponents(year: 2027, month: 1, day: 1))!)
        #expect(jan.weekStart.label("yyyy-MM-dd") == "2026-12-28")
        let leap = Day(Day.local.date(from: DateComponents(year: 2024, month: 2, day: 29))!)
        #expect(leap.monthLength == 29)
        #expect(leap.adding(1).label("yyyy-MM-dd") == "2024-03-01")
    }
}
