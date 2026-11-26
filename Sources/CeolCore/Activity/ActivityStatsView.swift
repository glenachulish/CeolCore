import Foundation
import SwiftUI
import SwiftData
import Charts

// FONN-ACTIVITY-1
// The record ActivityTracker keeps, as one page: this week day by day, a year
// of days as a calendar of squares, the most visited tunes, sets and
// collections, and week by week what moved on (stars raised, hitlist, tunes
// added, sets made). The same page on the iPhone, iPad and Mac.

/// The sums, worked out once from the records. Plain data, so the page only
/// draws it.
public struct ActivitySummary {
    public struct Bar: Identifiable {
        public var id: Date { date }
        public let date: Date
        public let minutes: Double
        public let isToday: Bool
    }

    public struct Top: Identifiable {
        public var id: String { kind.rawValue + uuid.uuidString }
        public let kind: ActivityVisit
        public let uuid: UUID
        public let title: String
        public let count: Int
    }

    public struct Cell: Identifiable {
        public var id: Date { date }
        public let date: Date
        /// nil for a day still to come.
        public let minutes: Double?
    }

    public struct Column: Identifiable {
        public var id: Date { start }
        public let start: Date
        public let cells: [Cell]
        /// "Nov" when the 1st of a month is in this week.
        public let month: String?
    }

    public struct Week: Identifiable {
        public var id: Date { start }
        public let start: Date
        public let minutes: Int
        public let starsUp: [String]
        public let starsDown: [String]
        public let hitlistOn: [String]
        public let tunesAdded: Int
        public let setsMade: Int
    }

    public var todayMinutes = 0.0
    public var weekMinutes = 0.0
    public var lastWeekMinutes = 0.0
    public var streak = 0
    public var bestStreak = 0
    public var bars: [Bar] = []
    public var columns: [Column] = []
    public var weekTunes = 0
    public var weekSets = 0
    public var weekCollections = 0
    public var topWeek: [ActivityVisit: [Top]] = [:]
    public var topAll: [ActivityVisit: [Top]] = [:]
    public var weeks: [Week] = []
    public var firstDay: Date?

    @MainActor
    public static func build(days: [ActivityDay], events: [ActivityEvent],
                             tunes: [Tune], sets: [TuneSet], collections: [TuneCollection],
                             now: Date = Date(), calendar: Calendar = .current) -> ActivitySummary {
        var s = ActivitySummary()
        var seconds: [String: Int] = [:]
        var visitsByDay: [String: [String: Int]] = [:]
        for day in days {
            seconds[day.day, default: 0] += day.activeSeconds
            for (key, n) in day.visitCounts { visitsByDay[day.day, default: [:]][key, default: 0] += n }
        }
        s.firstDay = seconds.keys.compactMap(ActivityCalendar.date).min()
        func minutes(_ date: Date) -> Double { Double(seconds[ActivityCalendar.key(date)] ?? 0) / 60 }

        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        func add(_ n: Int, to date: Date) -> Date { calendar.date(byAdding: .day, value: n, to: date) ?? date }

        s.todayMinutes = minutes(today)
        let thisWeek = (0..<7).map { add($0, to: weekStart) }
        s.bars = thisWeek.map { Bar(date: $0, minutes: minutes($0), isToday: $0 == today) }
        s.weekMinutes = s.bars.reduce(0) { $0 + $1.minutes }
        s.lastWeekMinutes = (1...7).map { minutes(add(-$0, to: weekStart)) }.reduce(0, +)

        // Streaks: days with at least a minute in Fonn. Today not yet counts
        // as unbroken.
        let used = Set(seconds.filter { $0.value >= 60 }.keys)
        var day = used.contains(ActivityCalendar.key(today)) ? today : add(-1, to: today)
        while used.contains(ActivityCalendar.key(day)) { s.streak += 1; day = add(-1, to: day) }
        let usedDates = used.compactMap(ActivityCalendar.date).map { calendar.startOfDay(for: $0) }.sorted()
        var run = 0
        var previous: Date?
        for date in usedDates {
            if let previous, add(1, to: previous) == date { run += 1 } else { run = 1 }
            s.bestStreak = max(s.bestStreak, run)
            previous = date
        }
        s.bestStreak = max(s.bestStreak, s.streak)

        // The year: 53 weeks, ending with this one.
        let monthName = DateFormatter()
        monthName.dateFormat = "MMM"
        s.columns = (0..<53).reversed().map { back in
            let start = add(-7 * back, to: weekStart)
            let cells = (0..<7).map { offset -> Cell in
                let date = add(offset, to: start)
                return Cell(date: date, minutes: date > today ? nil : minutes(date))
            }
            let first = cells.first { calendar.component(.day, from: $0.date) == 1 }
            return Column(start: start, cells: cells, month: first.map { monthName.string(from: $0.date) })
        }

        // Visits. A tune counts as its group: every version is one tune.
        var defaultOfGroup: [UUID: Tune] = [:]
        for tune in tunes where tune.isDefaultVersion {
            if let group = tune.groupID { defaultOfGroup[group] = tune }
        }
        let tuneByID = Dictionary(tunes.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let setByID = Dictionary(sets.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let collectionByID = Dictionary(collections.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })

        func tops(_ keys: [String]) -> [ActivityVisit: [Top]] {
            var counts: [String: Int] = [:]
            for key in keys { for (k, n) in visitsByDay[key] ?? [:] { counts[k, default: 0] += n } }
            var merged: [ActivityVisit: [UUID: (String, Int)]] = [:]
            for (k, n) in counts {
                let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let kind = ActivityVisit(rawValue: parts[0]),
                      let id = UUID(uuidString: parts[1]) else { continue }
                switch kind {
                case .tune:
                    guard let tune = tuneByID[id] else { continue }
                    let shown = tune.groupID.flatMap { defaultOfGroup[$0] } ?? tune
                    let old = merged[.tune]?[shown.uuid]?.1 ?? 0
                    merged[.tune, default: [:]][shown.uuid] = (TitleDisplay.spoken(shown.title), old + n)
                case .set:
                    guard let set = setByID[id] else { continue }
                    merged[.set, default: [:]][id] = (set.name, n)
                case .collection:
                    guard let collection = collectionByID[id] else { continue }
                    merged[.collection, default: [:]][id] = (collection.name, n)
                }
            }
            var result: [ActivityVisit: [Top]] = [:]
            for (kind, entries) in merged {
                result[kind] = entries
                    .map { Top(kind: kind, uuid: $0.key, title: $0.value.0, count: $0.value.1) }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title < $1.title }
            }
            return result
        }
        let weekKeys = thisWeek.map(ActivityCalendar.key)
        s.topWeek = tops(weekKeys)
        s.topAll = tops(Array(visitsByDay.keys))
        s.weekTunes = s.topWeek[.tune]?.count ?? 0
        s.weekSets = s.topWeek[.set]?.count ?? 0
        s.weekCollections = s.topWeek[.collection]?.count ?? 0

        // Week by week, the last twelve weeks with anything in them. The same
        // change noticed on two devices is one change.
        var seen = Set<String>()
        let unique = events.filter { event in
            let key = [event.kind, event.subject, String(event.fromValue), String(event.toValue),
                       ActivityCalendar.key(event.date)].joined(separator: "|")
            return seen.insert(key).inserted
        }
        func name(_ event: ActivityEvent) -> String {
            let title = UUID(uuidString: event.subject).flatMap { tuneByID[$0]?.title } ?? event.title
            return TitleDisplay.spoken(title)
        }
        for back in 0..<12 {
            let start = add(-7 * back, to: weekStart)
            let end = add(7, to: start)
            let inWeek = unique.filter { $0.date >= start && $0.date < end }.sorted { $0.date < $1.date }
            let up = inWeek.filter { $0.kind == "stars" && $0.toValue > $0.fromValue }
                .map { "\(name($0)) \(String(repeating: "★", count: $0.fromValue))→\(String(repeating: "★", count: $0.toValue))" }
            let down = inWeek.filter { $0.kind == "stars" && $0.toValue < $0.fromValue }.map(name)
            let hitlist = inWeek.filter { $0.kind == "hitlist" && $0.toValue == 1 }.map(name)
            let added = tunes.filter { $0.isDefaultVersion && $0.createdAt >= start && $0.createdAt < end }.count
            let made = sets.filter { $0.createdAt >= start && $0.createdAt < end }.count
            let mins = Int((0..<7).map { minutes(add($0, to: start)) }.reduce(0, +).rounded())
            if mins == 0 && up.isEmpty && down.isEmpty && hitlist.isEmpty && added == 0 && made == 0 { continue }
            s.weeks.append(Week(start: start, minutes: mins, starsUp: up, starsDown: down,
                                hitlistOn: hitlist, tunesAdded: added, setsMade: made))
        }
        return s
    }

    /// "1 h 25 min", "40 min", "0 min".
    public static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) min" }
        let m = total % 60
        return m == 0 ? "\(total / 60) h" : "\(total / 60) h \(m) min"
    }
}

public struct ActivityStatsView: View {
    @Query private var days: [ActivityDay]
    @Query private var events: [ActivityEvent]
    @Query private var tunes: [Tune]
    @Query private var sets: [TuneSet]
    @Query private var collections: [TuneCollection]
    @State private var allTime = false

    let openTune: (Tune) -> Void
    let openSet: (TuneSet) -> Void
    let openCollection: (TuneCollection) -> Void

    public init(openTune: @escaping (Tune) -> Void,
                openSet: @escaping (TuneSet) -> Void,
                openCollection: @escaping (TuneCollection) -> Void) {
        self.openTune = openTune
        self.openSet = openSet
        self.openCollection = openCollection
    }

    public var body: some View {
        let s = ActivitySummary.build(days: days, events: events, tunes: tunes,
                                      sets: sets, collections: collections)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if s.firstDay == nil {
                    Text("Fonn starts keeping this record now. Come back after you've played for a while: the time you spend in Fonn, the tunes, sets and collections you open, and the stars you give will build up here, day by day, on all your devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                headline(s)
                weekChart(s)
                heatmap(s)
                topLists(s)
                timeline(s)
                Text("Time counts while Fonn is on screen and in use; it pauses after five minutes with no touch, click or key. Kept in iCloud, so your devices add up to one record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { ActivityTracker.shared.flush() }
    }

    // MARK: Headline

    private func headline(_ s: ActivitySummary) -> some View {
        let change = s.weekMinutes - s.lastWeekMinutes
        return HStack(spacing: 10) {
            tile("Today", ActivitySummary.duration(s.todayMinutes), nil)
            tile("This week", ActivitySummary.duration(s.weekMinutes),
                 s.lastWeekMinutes == 0 && s.weekMinutes == 0 ? nil
                 : (change >= 0 ? "▲ " : "▼ ") + ActivitySummary.duration(abs(change)) + " on last week")
            tile("Streak", s.streak == 1 ? "1 day" : "\(s.streak) days",
                 s.bestStreak > 0 ? "Best \(s.bestStreak)" : nil)
        }
    }

    private func tile(_ title: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(note ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: This week

    private func weekChart(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("This week")
            Chart(s.bars) { bar in
                BarMark(x: .value("Day", bar.date, unit: .day),
                        y: .value("Minutes", bar.minutes))
                    .foregroundStyle(bar.isToday ? Color.accentColor : Color.accentColor.opacity(0.45))
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        if bar.minutes >= 1 {
                            Text("\(Int(bar.minutes.rounded()))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .chartYAxisLabel("minutes")
            .frame(height: 170)
            Text("Opened this week: \(count(s.weekTunes, "tune")), \(count(s.weekSets, "set")), \(count(s.weekCollections, "collection")). Last week: \(ActivitySummary.duration(s.lastWeekMinutes)) in Fonn.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: The year

    private func heatmap(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("The year")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(s.columns) { column in
                            VStack(spacing: 3) {
                                Text(column.month ?? " ")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .frame(width: 13, height: 12, alignment: .leading)
                                ForEach(column.cells) { cell in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(colour(for: cell.minutes))
                                        .frame(width: 13, height: 13)
                                        .help(cellHelp(cell))
                                }
                            }
                            .id(column.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear {
                    if let last = s.columns.last { proxy.scrollTo(last.id, anchor: .trailing) }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach([0.0, 5, 20, 45, 90], id: \.self) { m in
                    RoundedRectangle(cornerRadius: 3).fill(colour(for: m)).frame(width: 11, height: 11)
                }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func colour(for minutes: Double?) -> Color {
        guard let minutes else { return .clear }
        switch minutes {
        case ..<1: return Color.secondary.opacity(0.12)
        case ..<10: return Color.green.opacity(0.3)
        case ..<30: return Color.green.opacity(0.5)
        case ..<60: return Color.green.opacity(0.72)
        default: return Color.green
        }
    }

    private func cellHelp(_ cell: ActivitySummary.Cell) -> String {
        let day = cell.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard let minutes = cell.minutes else { return day }
        return "\(day): \(ActivitySummary.duration(minutes))"
    }

    // MARK: Most visited

    private func topLists(_ s: ActivitySummary) -> some View {
        let tops = allTime ? s.topAll : s.topWeek
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Most visited")
                Spacer()
                Picker("When", selection: $allTime) {
                    Text("This week").tag(false)
                    Text("All time").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            topGroup("Tunes", tops[.tune] ?? [])
            topGroup("Sets", tops[.set] ?? [])
            topGroup("Collections", tops[.collection] ?? [])
        }
    }

    private func topGroup(_ title: String, _ entries: [ActivitySummary.Top]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline.weight(.semibold)).padding(.bottom, 4)
            if entries.isEmpty {
                Text(allTime ? "None opened yet." : "None opened this week.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            let most = Double(entries.first?.count ?? 1)
            ForEach(Array(entries.prefix(5).enumerated()), id: \.element.id) { index, entry in
                Button { open(entry) } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(entry.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Capsule().fill(Color.accentColor.opacity(0.35))
                            .frame(width: max(6, 70 * Double(entry.count) / max(most, 1)), height: 6)
                        Text("\(entry.count)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func open(_ entry: ActivitySummary.Top) {
        switch entry.kind {
        case .tune: if let tune = tunes.first(where: { $0.uuid == entry.uuid }) { openTune(tune) }
        case .set: if let set = sets.first(where: { $0.uuid == entry.uuid }) { openSet(set) }
        case .collection:
            if let collection = collections.first(where: { $0.uuid == entry.uuid }) { openCollection(collection) }
        }
    }

    // MARK: Week by week

    private func timeline(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Week by week")
            if s.weeks.isEmpty {
                Text("Nothing yet in the last twelve weeks.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(s.weeks) { week in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle().fill(Color.accentColor).frame(width: 9, height: 9).padding(.top, 5)
                        Rectangle().fill(Color.accentColor.opacity(0.25)).frame(width: 2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Week of " + week.start.formatted(.dateTime.day().month(.wide)))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if week.minutes > 0 {
                                Text(ActivitySummary.duration(Double(week.minutes)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        if !week.starsUp.isEmpty {
                            line("star.fill", .yellow, "Stars raised: " + week.starsUp.joined(separator: ", "))
                        }
                        if !week.hitlistOn.isEmpty {
                            line("target", .orange, "Onto the hitlist: " + week.hitlistOn.joined(separator: ", "))
                        }
                        if week.tunesAdded > 0 {
                            line("plus.circle", .green, count(week.tunesAdded, "tune") + " added")
                        }
                        if week.setsMade > 0 {
                            line("square.stack", .blue, count(week.setsMade, "set") + " made")
                        }
                        if !week.starsDown.isEmpty {
                            line("star", .secondary, "Stars lowered: " + week.starsDown.joined(separator: ", "))
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func line(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        Label {
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint).font(.caption)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}
