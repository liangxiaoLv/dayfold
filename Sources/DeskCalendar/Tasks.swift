import SwiftUI

struct TaskEditor: View {
    let space: Workspace
    let close: () -> Void
    @ViewState private var draft: CalendarTask
    @ViewState private var clock: Date
    @ViewState private var problem: String?
    @ViewState private var saving = false
    @ViewState private var deleting = false
    @FocusState private var titleFocused: Bool
    private let existing: Bool

    init(space: Workspace, item: CalendarTask, close: @escaping () -> Void) {
        self.space = space
        self.close = close
        existing = space.store.tasks.contains { $0.id == item.id }
        _draft = State(initialValue: item)
        let minute = item.reminderMinute ?? 540
        _clock = State(initialValue: Day.local.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: item.due.date) ?? item.due.date)
    }
    private var minute: Int { Day.local.component(.hour, from: clock) * 60 + Day.local.component(.minute, from: clock) }
    private func date(_ path: WritableKeyPath<CalendarTask, Day>) -> Binding<Date> {
        Binding(get: { draft[keyPath: path].date }, set: {
            let value = Day($0)
            if path == \CalendarTask.start && draft.end < value { draft.end = value }
            draft[keyPath: path] = value
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("任务标题", text: $draft.title).textFieldStyle(.roundedBorder)
                .font(.title3).focused($titleFocused).accessibilityLabel("任务标题")
            Form {
                Picker("优先级", selection: $draft.priority) {
                    ForEach(Priority.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Section {
                    DatePicker("开始日期", selection: date(\.start), displayedComponents: .date)
                    DatePicker("结束日期", selection: date(\.end), in: draft.start.date..., displayedComponents: .date)
                }
                Section {
                    DatePicker("截止日期", selection: date(\.due), displayedComponents: .date)
                    Toggle("截止日提醒", isOn: Binding(get: { draft.reminderMinute != nil }, set: { draft.reminderMinute = $0 ? minute : nil }))
                    if draft.reminderMinute != nil {
                        DatePicker("提醒时间", selection: $clock, displayedComponents: .hourAndMinute)
                    }
                }
            }.formStyle(.grouped)
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if existing {
                    Button(role: .destructive) { deleting = true } label: { Image(systemName: "trash") }.help("删除整项任务")
                }
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }.padding(18).disabled(saving)
            .onAppear { titleFocused = true }
            .alert("删除整项任务？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    do { try space.store.delete(draft.id); close() } catch { problem = error.localizedDescription }
                }
            } message: { Text("此任务和每天的完成记录将一起移除。") }
    }
    @MainActor private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            if draft.reminderMinute != nil {
                draft.reminderMinute = minute
                let old = space.store.tasks.first { $0.id == draft.id }
                if old?.due != draft.due || old?.reminderMinute != draft.reminderMinute {
                    var pending = draft
                    pending.checked = []
                    guard let when = pending.reminderDate, when > Date() else {
                        problem = "请选择将来的提醒时间，或关闭截止日提醒。"; return
                    }
                    guard try await space.reminders.authorize() else {
                        problem = "请在系统设置的「通知」中允许桌面待办日历发送通知，或关闭此任务的提醒后保存。"; return
                    }
                }
            }
            try space.store.save(draft)
            close()
        } catch { problem = error.localizedDescription }
    }
}

struct Overview: View {
    @ObservedObject var space: Workspace
    @ObservedObject var store: TaskStore
    @ViewState private var filter = 0
    @ViewState private var query = ""
    @ViewState private var date = Date()
    private var visible: [CalendarTask] {
        store.tasks.filter {
            (filter == 0 || ($0.finished == (filter == 2))) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }.sorted { $0.due == $1.due ? $0.title < $1.title : $0.due < $1.due }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("任务总览").font(.largeTitle.bold())
                Spacer()
                Button { space.edit(CalendarTask(on: space.today)) } label: { Label("新增待办", systemImage: "plus") }
            }
            let day = Day(date)
            let daily = store.on(day)
            HStack {
                DatePicker("每日统计", selection: $date, displayedComponents: .date)
                Spacer()
                Text("当天已完成 \(daily.filter { $0.checked.contains(day) }.count)/\(daily.count) 项").monospacedDigit()
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            let finished = store.tasks.filter(\.finished).count
            HStack {
                Picker("状态", selection: $filter) {
                    Text("全部 \(store.tasks.count)").tag(0)
                    Text("进行中 \(store.tasks.count - finished)").tag(1)
                    Text("已完成 \(finished)").tag(2)
                }.labelsHidden().pickerStyle(.segmented)
                TextField("搜索标题", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 145)
            }
            if visible.isEmpty {
                ContentUnavailableView(store.tasks.isEmpty ? "还没有待办" : "没有匹配的任务",
                                       systemImage: "calendar", description: Text(store.tasks.isEmpty ? "点击桌面日历上的日期即可添加。" : "试试其他标题或状态。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { item in
                            Button { space.edit(item) } label: {
                                HStack {
                                    Circle().fill(item.priority.color).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title).font(.headline).lineLimit(1)
                                        Text("\(item.start.label("M/d")) – \(item.end.label("M/d"))   ·   \(item.priority.label)优先级   ·   \(item.due.label("M/d")) 截止")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text("已完成 \(item.checked.count)/\(item.total) 天").font(.caption.monospacedDigit())
                                        ProgressView(value: Double(item.checked.count), total: Double(item.total)).frame(width: 85)
                                    }
                                }.padding(.vertical, 9).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }.padding(20)
    }
}
