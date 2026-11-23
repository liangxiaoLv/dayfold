import SwiftUI

// Use the property wrapper with Command Line Tools SDKs that omit SwiftUI macro plugins.
typealias ViewState<Value> = SwiftUI.State<Value>

private let herb = Color(red: 0.77, green: 0.91, blue: 0.68)
private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

struct BoardView: View {
    @ObservedObject var space: Workspace
    @ObservedObject var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var datePicker = false
    @ViewState private var choosingPlacement = false
    private var period: String {
        switch space.mode {
        case .day: return space.anchor.label("yyyy年M月d日")
        case .month: return space.anchor.label("yyyy年M月")
        case .week:
            let start = space.anchor.weekStart, end = start.adding(6)
            return start.label("yyyy.M.d") + " – " + end.label(start.label("yyyy") == end.label("yyyy") ? "M.d" : "yyyy.M.d")
        }
    }
    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 600
            VStack(alignment: .leading, spacing: compact ? 8 : 14) {
                HStack {
                    Picker("日历视图", selection: $space.mode) {
                        ForEach(CalendarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 120)
                    Spacer()
                    Button { space.openOverview() } label: { Label("总览", systemImage: "list.bullet.rectangle") }
                    Button { space.pinned.toggle() } label: { Image(systemName: space.pinned ? "pin.fill" : "pin") }
                        .foregroundStyle(space.pinned ? herb : .white).help(space.pinned ? "取消置顶" : "置顶")
                    Button { choosingPlacement.toggle() } label: { Image(systemName: "rectangle.split.2x2") }
                        .help("桌面占用范围与位置").accessibilityLabel("桌面布局")
                        .popover(isPresented: $choosingPlacement) {
                            PlacementPicker(selected: space.placement) { placement in
                                choosingPlacement = false
                                space.placement = placement
                            }
                        }
                    Button("缩小") { space.collapse() }
                        .help("缩小为可拖动的一行")
                }.buttonStyle(.borderless)
                HStack(spacing: 8) {
                    Button { datePicker.toggle() } label: {
                        HStack(spacing: 6) {
                            Text(period).font(.system(size: compact ? 19 : 26, weight: .semibold, design: .rounded))
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }.popover(isPresented: $datePicker) {
                        VStack(alignment: .leading, spacing: 6) {
                            if space.mode == .week {
                                ForEach(0..<3, id: \.self) { index in
                                    let start = space.today.weekStart.adding(-7 * index)
                                    Button {
                                        space.anchor = start
                                        datePicker = false
                                    } label: {
                                        HStack {
                                            Text(["本周", "上周", "前两周"][index])
                                            Spacer()
                                            Text(start.label("M/d") + " – " + start.adding(6).label("M/d"))
                                                .foregroundStyle(.secondary)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                                Divider()
                            }
                            DatePicker("跳转日期", selection: Binding(get: { space.anchor.date }, set: {
                                space.anchor = Day($0)
                                datePicker = false
                            }), displayedComponents: .date).datePickerStyle(.graphical)
                        }.padding(12)
                    }
                    Spacer(minLength: 0)
                    Button { space.step(-1) } label: { Image(systemName: "chevron.left") }.help("上一时段")
                    Button("今天") { space.anchor = space.today }.help("回到当前日期")
                    Button { space.step(1) } label: { Image(systemName: "chevron.right") }.help("下一时段")
                }.buttonStyle(.plain)
                CalendarGrid(space: space, store: store)
            }
            .padding(compact ? 12 : 18)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: compact ? 21 : 28)
                    .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.20, blue: 0.18).opacity(0.85),
                                                   Color(red: 0.10, green: 0.13, blue: 0.14).opacity(0.76)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { RoundedRectangle(cornerRadius: compact ? 21 : 28).strokeBorder(.white.opacity(0.18)).allowsHitTesting(false) }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: space.mode)
        }
        .preferredColorScheme(.dark)
        .alert("任务日历", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct CompactBar: View {
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Label("折历", systemImage: "calendar")
                .font(.callout.weight(.medium))
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay { WindowDragArea().help("拖动窄栏") }
            Button("展开", action: expand)
                .buttonStyle(.bordered)
                .padding(.trailing, 8)
        }
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.14, green: 0.20, blue: 0.18).opacity(0.94)))
        .preferredColorScheme(.dark)
    }
}

private struct WindowDragArea: NSViewRepresentable {
    final class Handle: NSView {
        private var grabOffset: NSPoint?
        private var moved = false
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            moved = false
            grabOffset = event.locationInWindow
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let grabOffset else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y))
            moved = true
        }
        override func mouseUp(with event: NSEvent) {
            if moved { window?.saveFrame(usingName: compactBarFrameName) }
            grabOffset = nil
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ nsView: Handle, context: Context) {}
}

private struct PlacementPicker: View {
    let selected: Placement
    let select: (Placement) -> Void
    private let groups: [[Placement]] = [
        [.full, .left, .right],
        [.upperLeft, .upperRight, .lowerLeft, .lowerRight]
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.self) { group in
                HStack(spacing: 6) {
                    ForEach(group, id: \.self) { option in
                        Button { select(option) } label: {
                            VStack(spacing: 4) {
                                Canvas { context, size in
                                    let bounds = CGRect(origin: .zero, size: size)
                                    let region = option.frame(in: bounds)
                                    let flipped = CGRect(x: region.minX, y: size.height - region.maxY,
                                                         width: region.width, height: region.height)
                                    context.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(.secondary.opacity(0.25)))
                                    context.fill(Path(roundedRect: flipped.insetBy(dx: 2, dy: 2), cornerRadius: 2),
                                                 with: .color(option == selected ? .accentColor : .secondary))
                                }.frame(width: 38, height: 25)
                                Text(option.rawValue).font(.caption)
                            }.frame(width: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(12)
    }
}

private struct CalendarGrid: View {
    @ObservedObject var space: Workspace
    @ObservedObject var store: TaskStore
    var body: some View {
        GeometryReader { geometry in
            let month = space.mode == .month
            let week = space.mode == .week
            let first = month ? space.anchor.monthStart.weekStart : (week ? space.anchor.weekStart : space.anchor)
            let monthWeeks = (space.anchor.monthStart.weekday + space.anchor.monthLength + 6) / 7
            let count = month ? monthWeeks * 7 : (week ? 7 : 1)
            let columns = month ? 7 : (week ? (geometry.size.width >= 1120 ? 7 : 4) : 1)
            let rows = (count + columns - 1) / columns
            let gap: CGFloat = month ? 3 : 6
            let heading: CGFloat = month ? 21 : 0
            let cellHeight = max(month ? 40 : 72, (geometry.size.height - heading - CGFloat(rows - 1) * gap) / CGFloat(rows))
            let cellWidth = (geometry.size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            VStack(spacing: 0) {
                if month {
                    HStack(spacing: gap) {
                        ForEach(weekdays, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                    }.frame(height: heading)
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: gap), count: columns), spacing: gap) {
                        ForEach(0..<count, id: \.self) { offset in
                            let day = first.adding(offset)
                            DayCell(space: space, store: store, day: day, items: store.on(day), height: cellHeight,
                                    compact: month, narrow: cellWidth < 95,
                                    outside: month && day.monthStart != space.anchor.monthStart)
                                .frame(height: cellHeight)
                                .id(day)
                        }
                    }
                }.scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

private struct DayCell: View {
    @ObservedObject var space: Workspace
    @ObservedObject var store: TaskStore
    let day: Day
    let items: [CalendarTask]
    let height: CGFloat
    let compact: Bool
    let narrow: Bool
    let outside: Bool
    @ViewState private var expanded = false
    private var isToday: Bool { day == space.today }
    private var capacity: Int {
        let available = height - (compact ? 32 : 54)
        let full = max(0, Int(available / (compact ? 23 : 29)))
        return items.count > full ? max(0, full - 1) : full
    }
    private var dateButton: some View {
        Button { space.edit(CalendarTask(on: day)) } label: {
            HStack(spacing: 4) {
                Text(String(day.number))
                    .font(.system(size: compact ? 12 : 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(isToday ? Color.black : .white)
                    .frame(minWidth: compact ? 18 : 25, minHeight: compact ? 18 : 25)
                    .background { if isToday { Circle().fill(herb) } }
                if !compact { Text("周" + weekdays[day.weekday]).font(.caption).foregroundStyle(.secondary) }
            }
        }.buttonStyle(.plain).help(day.label("M月d日") + " · 新增待办")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(spacing: 2) {
                dateButton
                Spacer(minLength: 0)
                if compact && capacity == 0 && !items.isEmpty {
                    Button { expanded = true } label: { Text("\(items.count)").font(.caption2.bold()).foregroundStyle(herb) }
                        .buttonStyle(.plain).help("查看当天全部待办")
                }
            }
            if !compact { Divider().opacity(0.55) }
            ForEach(items.prefix(capacity)) { item in
                TaskLine(store: store, item: item, day: day, compact: compact, narrow: narrow, edit: { space.edit(item) })
            }
            if items.count > capacity && !(compact && capacity == 0) {
                Button(narrow ? "+\(items.count - capacity)" : "还有 \(items.count - capacity) 项") { expanded = true }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(herb)
            }
            if space.mode == .day && items.isEmpty {
                Button { space.edit(CalendarTask(on: day)) } label: { Label("新增待办", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 4 : (narrow ? 5 : 9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: compact ? 6 : 12).fill(.white.opacity(isToday ? 0.12 : 0.06)))
        .opacity(outside ? 0.53 : 1)
        .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(day.label("M月d日 EEEE")).font(.headline)
                    Spacer()
                    Button { expanded = false; space.edit(CalendarTask(on: day)) } label: { Image(systemName: "plus") }
                }
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(items) { item in
                            TaskLine(store: store, item: item, day: day, compact: false, narrow: false, edit: {
                                expanded = false; space.edit(item)
                            })
                        }
                    }
                }.frame(height: min(290, CGFloat(items.count) * 30))
            }.padding(14).frame(width: 270)
        }
    }
}

private struct TaskLine: View {
    @ObservedObject var store: TaskStore
    let item: CalendarTask
    let day: Day
    let compact: Bool
    let narrow: Bool
    let edit: () -> Void
    var body: some View {
        let done = item.checked.contains(day)
        HStack(spacing: narrow ? 2 : 5) {
            Button { store.toggle(item.id, on: day) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? herb : item.priority.color)
                    .frame(minWidth: compact ? 13 : 17, minHeight: compact ? 17 : 22)
            }.accessibilityLabel((done ? "取消完成 " : "完成 ") + item.title)
            Button(action: edit) {
                HStack {
                    Text(item.title).strikethrough(done).lineLimit(1)
                    Spacer(minLength: 0)
                    if !compact && !narrow { Text(item.due.label("M/d")).font(.caption2).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.opacity(done ? 0.55 : 1)
        }.buttonStyle(.plain).font(compact ? .caption : .callout)
            .frame(height: compact ? 21 : 25)
            .help("\(item.title) · \(item.priority.label)优先级 · \(item.due.label("M月d日"))截止")
    }
}
