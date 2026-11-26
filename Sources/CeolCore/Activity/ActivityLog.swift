import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#elseif canImport(AppKit)
import AppKit
#endif

// FONN-ACTIVITY-1
// How much Fonn is used, and what is opened in it: a day-by-day record kept in
// iCloud with the library, so the iPhone, iPad and Mac add up to one record.
//
// - Time in use: the app on screen, counted in 15-second steps, paused once
//   five minutes go by with no touch, click, key or page opened.
// - Visits: each tune, set and collection page opened (the same place
//   reported twice within ten minutes counts once).
// - Marks: stars raised or lowered and tunes put on or taken off the hitlist,
//   noticed by comparing with what this device saw last (so a change made on
//   another device is noticed too; the stats page counts it once).
//
// One ActivityDay per calendar day per device, so two devices never write to
// the same record and CloudKit never has to merge them.
//
// CloudKit rules, as in Models.swift: every attribute defaulted, no unique
// constraints. **Two new record types (CD_ActivityDay, CD_ActivityEvent) need
// Deploy Schema Changes to Production before a TestFlight build ships them.**

@Model
public final class ActivityDay {
    public var uuid: UUID = UUID()
    /// The device's own calendar day, "2026-11-25".
    public var day: String = ""
    /// Which device, so each writes only its own record.
    public var device: String = ""
    public var activeSeconds: Int = 0
    /// JSON: {"t:<tune uuid>": 3, "s:<set uuid>": 1, "c:<collection uuid>": 2}
    public var visits: String = ""
    public var updatedAt: Date = Date()

    public init(day: String = "", device: String = "") {
        self.day = day
        self.device = device
    }

    public var visitCounts: [String: Int] {
        guard let data = visits.data(using: .utf8),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return counts
    }
}

@Model
public final class ActivityEvent {
    public var uuid: UUID = UUID()
    public var date: Date = Date()
    /// "stars" or "hitlist".
    public var kind: String = ""
    /// The tune's uuid.
    public var subject: String = ""
    public var title: String = ""
    /// Stars before and after; for the hitlist 0 = off, 1 = on.
    public var fromValue: Int = 0
    public var toValue: Int = 0
    public var device: String = ""

    public init(kind: String = "", subject: String = "", title: String = "",
                fromValue: Int = 0, toValue: Int = 0, device: String = "") {
        self.kind = kind
        self.subject = subject
        self.title = title
        self.fromValue = fromValue
        self.toValue = toValue
        self.device = device
    }
}

/// Day keys ("2026-11-25"), in the device's own time zone.
public enum ActivityCalendar {
    static let format: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func key(_ date: Date) -> String { format.string(from: date) }
    public static func date(_ key: String) -> Date? { format.date(from: key) }
}

public enum ActivityVisit: String {
    case tune = "t", set = "s", collection = "c"
}

@MainActor
public final class ActivityTracker {
    public static let shared = ActivityTracker()

    /// No input for this long and the clock stops until the next one.
    public static let idleLimit: TimeInterval = 5 * 60
    static let step: TimeInterval = 15

    /// This device's name in the record: made once, kept in UserDefaults.
    public let device: String = {
        let key = "fonn.activity.device"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private var context: ModelContext?
    private var timer: Timer?
    private var active = false
    private var lastTick: Date?
    private var lastInput = Date()
    private var pendingSeconds: Double = 0
    private var pendingVisits: [String: Int] = [:]
    private var recentVisits: [String: Date] = [:]
    private var lastFlush = Date()
    private var observers: [NSObjectProtocol] = []
    #if canImport(AppKit) && !canImport(UIKit)
    private var eventMonitor: Any?
    #endif

    private init() {}

    #if canImport(UIKit)
    /// The app's windows, for the touch watcher. Handed in by the phone app:
    /// `UIApplication.shared` can't be named in CeolCore, which the share
    /// extension links too.
    public var windows: (() -> [UIWindow])?
    #endif

    /// Once, at launch, with the main context (the one the windows use).
    /// The app is on screen when it calls this.
    public func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        let centre = NotificationCenter.default
        #if canImport(UIKit)
        observers.append(centre.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ActivityTracker.shared.becameActive() }
        })
        observers.append(centre.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ActivityTracker.shared.resigned() }
        })
        becameActive()
        #elseif canImport(AppKit)
        observers.append(centre.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ActivityTracker.shared.becameActive() }
        })
        observers.append(centre.addObserver(forName: NSApplication.didResignActiveNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ActivityTracker.shared.resigned() }
        })
        observers.append(centre.addObserver(forName: NSApplication.willTerminateNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ActivityTracker.shared.resigned() }
        })
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { ActivityTracker.shared.noteInput() }
            return event
        }
        if NSApplication.shared.isActive { becameActive() }
        #endif
        // Wait for the library to load (and iCloud to bring the marks in)
        // before the first comparison.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            ActivityTracker.shared.checkMarks()
        }
    }

    /// A touch, click, key or scroll: you are here.
    public func noteInput() {
        lastInput = Date()
    }

    /// A tune, set or collection page was opened.
    public func visit(_ kind: ActivityVisit, _ id: UUID) {
        noteInput()
        let key = kind.rawValue + ":" + id.uuidString
        let now = Date()
        if let last = recentVisits[key], now.timeIntervalSince(last) < 600 { return }
        recentVisits[key] = now
        pendingVisits[key, default: 0] += 1
    }

    private func becameActive() {
        active = true
        lastTick = Date()
        noteInput()
        #if canImport(UIKit)
        installTouchWatcher()
        #endif
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.step, repeats: true) { _ in
            MainActor.assumeIsolated { ActivityTracker.shared.tick() }
        }
    }

    private func resigned() {
        tick()
        active = false
        timer?.invalidate()
        timer = nil
        flush()
        checkMarks()
    }

    private func tick() {
        let now = Date()
        let previous = lastTick
        lastTick = now
        guard active, let previous else { return }
        // A long gap means the app was asleep, not in use.
        let gap = min(now.timeIntervalSince(previous), Self.step + 5)
        if now.timeIntervalSince(lastInput) <= Self.idleLimit, gap > 0 {
            pendingSeconds += gap
        }
        if now.timeIntervalSince(lastFlush) >= 60 {
            flush()
            checkMarks()
        }
    }

    /// Adds what has been counted to today's record for this device.
    public func flush() {
        lastFlush = Date()
        let seconds = Int(pendingSeconds.rounded(.down))
        guard let context, seconds > 0 || !pendingVisits.isEmpty else { return }
        let key = ActivityCalendar.key(Date())
        let device = self.device
        let record: ActivityDay
        if let existing = try? context.fetch(FetchDescriptor<ActivityDay>(
            predicate: #Predicate { $0.day == key && $0.device == device })).first {
            record = existing
        } else {
            record = ActivityDay(day: key, device: device)
            context.insert(record)
        }
        record.activeSeconds += seconds
        if !pendingVisits.isEmpty {
            var counts = record.visitCounts
            for (visit, n) in pendingVisits { counts[visit, default: 0] += n }
            if let data = try? JSONEncoder().encode(counts) {
                record.visits = String(decoding: data, as: UTF8.self)
            }
        }
        record.updatedAt = Date()
        pendingSeconds -= Double(seconds)
        pendingVisits = [:]
        try? context.save()
    }

    // MARK: Stars and hitlist

    private struct Mark: Codable, Equatable {
        var stars: Int
        var hitlist: Bool
    }

    private static var marksFile: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("marks.json")
    }

    /// Compares every tune's stars and hitlist with what this device saw
    /// last, and records what changed. The first time, it only takes note.
    public func checkMarks() {
        guard let context, let file = Self.marksFile,
              let tunes = try? context.fetch(FetchDescriptor<Tune>()) else { return }
        var now: [String: Mark] = [:]
        for tune in tunes {
            now[tune.uuid.uuidString] = Mark(stars: tune.rating, hitlist: tune.onHitlist)
        }
        guard let data = try? Data(contentsOf: file),
              let before = try? JSONDecoder().decode([String: Mark].self, from: data) else {
            if !tunes.isEmpty, let out = try? JSONEncoder().encode(now) { try? out.write(to: file) }
            return
        }
        guard now != before else { return }
        let byID = Dictionary(tunes.map { ($0.uuid.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        var added = false
        for (id, mark) in now {
            guard let old = before[id], let tune = byID[id] else { continue }
            if old.stars != mark.stars {
                added = record("stars", tune, old.stars, mark.stars, in: context) || added
            }
            if old.hitlist != mark.hitlist {
                added = record("hitlist", tune, old.hitlist ? 1 : 0, mark.hitlist ? 1 : 0, in: context) || added
            }
        }
        if added { try? context.save() }
        if let out = try? JSONEncoder().encode(now) { try? out.write(to: file) }
    }

    /// Not again if the same change is already recorded in the last two
    /// days: another device saw it first and iCloud brought its note here.
    private func record(_ kind: String, _ tune: Tune, _ from: Int, _ to: Int,
                        in context: ModelContext) -> Bool {
        let subject = tune.uuid.uuidString
        let since = Date().addingTimeInterval(-2 * 86_400)
        let known = (try? context.fetch(FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.subject == subject && $0.kind == kind && $0.date > since }))) ?? []
        if known.contains(where: { $0.toValue == to && $0.fromValue == from }) { return false }
        context.insert(ActivityEvent(kind: kind, subject: subject, title: tune.title,
                                     fromValue: from, toValue: to, device: device))
        return true
    }

    // MARK: Touches (iPhone and iPad)

    #if canImport(UIKit)
    private var watched = Set<ObjectIdentifier>()

    /// A recogniser on each window that sees every touch and stops none.
    private func installTouchWatcher() {
        for window in windows?() ?? [] where !watched.contains(ObjectIdentifier(window)) {
            watched.insert(ObjectIdentifier(window))
            let watcher = TouchWatcher(target: nil, action: nil)
            watcher.cancelsTouchesInView = false
            watcher.delaysTouchesBegan = false
            watcher.delaysTouchesEnded = false
            watcher.delegate = TouchWatcher.delegateInstance
            window.addGestureRecognizer(watcher)
        }
    }
    #endif
}

#if canImport(UIKit)
/// Notes each touch, then fails, so it never takes a touch from anything.
private final class TouchWatcher: UIGestureRecognizer {
    static let delegateInstance = TouchWatcherDelegate()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        MainActor.assumeIsolated { ActivityTracker.shared.noteInput() }
        state = .failed
    }
}

private final class TouchWatcherDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
