import Foundation
import SwiftUI
import SwiftData

// FONN-TEMPOCHECK-1
/// Finds tunes whose written tempo (the Q: line) is far from how that kind of
/// tune is played, and sets the type's standard tempo instead.
///
/// Plenty of tunes arrive marked at a tempo nobody plays: a reel at 300, a
/// strathspey at 200, an air at 10. The tune page plays whatever Q: says, so
/// one of those starts at a gallop or a crawl every time it is opened.
///
/// "Far from" is measured in the beats a player counts (minims in a reel,
/// dotted crotchets in a jig: see `TuneTypeDefaults`): under half the
/// standard, or more than 1.6 times it, is flagged. A brisk session tempo
/// stays well inside that. Only tunes with a type are judged, since a tempo
/// can't be called wrong without knowing what the tune is; the page says how
/// many odd ones were passed over for having none.
///
/// The change is made with the layout tidy's backup and Undo
/// (`LibraryTidy.apply` / `undo`), in a folder of its own.
public enum LibraryTempo {

    public static let backupKind = "TempoCheck"

    /// Under this many times the standard, or over the upper one, is flagged.
    static let lowFactor = 0.5
    static let highFactor = 1.6

    public struct Finding: Sendable, Identifiable {
        public var id: UUID { uuid }
        public let uuid: UUID
        public let title: String
        public let type: String
        /// In the beats a player counts, as written and as it will be.
        public let written: Int
        public let standard: Int
        public let beatName: String
        public let before: String
        public let after: String
    }

    public struct Scan: Sendable {
        public let findings: [Finding]
        /// Tunes with an impossible tempo (under 20 or over 400 crotchets a
        /// minute) but no type to choose a better one from.
        public let untypedOdd: Int
    }

    /// A Q: line read: any words, the beat (num/den, nil for a bare number)
    /// and the number.
    struct Written {
        let lineIndex: Int
        let words: String?
        let num: Int
        let den: Int
        let bpm: Int
        let bare: Bool
    }

    private static let qPattern = try! NSRegularExpression(
        pattern: #"^Q:\s*(?:"([^"]*)"\s*)?(?:(\d+)\s*/\s*(\d+)\s*=\s*)?(\d+)\s*(?:"([^"]*)")?\s*$"#)

    /// The first Q: line of the header (before K:), if it gives a number.
    static func written(in lines: [String]) -> Written? {
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("K:") { return nil }
            guard line.hasPrefix("Q:") else { continue }
            let ns = line as NSString
            guard let m = qPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            func group(_ n: Int) -> String? {
                let r = m.range(at: n)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard let bpm = group(4).flatMap(Int.init), bpm > 0 else { return nil }
            let words = group(1) ?? group(5)
            if let n = group(2).flatMap(Int.init), let d = group(3).flatMap(Int.init), n > 0, d > 0 {
                return Written(lineIndex: i, words: words, num: n, den: d, bpm: bpm, bare: false)
            }
            // A bare number is taken as crotchets, as the music page plays it.
            return Written(lineIndex: i, words: words, num: 1, den: 4, bpm: bpm, bare: true)
        }
        return nil
    }

    /// The written time signature, C and C| spelled out.
    static func meter(in lines: [String]) -> String {
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("K:") { break }
            if line.hasPrefix("M:") {
                let m = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
                if m == "C" { return "4/4" }
                if m == "C|" { return "2/2" }
                return m.isEmpty ? "4/4" : m
            }
        }
        return "4/4"
    }

    /// The counted beat for a meter and type: (num, den) of a whole note.
    static func countedBeat(meter: String, type: String) -> (num: Int, den: Int)? {
        let counting = TuneTypeDefaults.countingMeter(meter, type: type)
        let parts = counting.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        if parts[1] == 8 && parts[0] % 3 == 0 { return (3, 8) }
        return (1, parts[1])
    }

    static func beatName(_ beat: (num: Int, den: Int)) -> String {
        switch (beat.num, beat.den) {
        case (1, 2): return "minims"
        case (1, 4): return "crotchets"
        case (1, 8): return "quavers"
        case (3, 8): return "dotted crotchets"
        case (3, 4): return "dotted minims"
        default: return "\(beat.num)/\(beat.den) beats"
        }
    }

    /// The finding for one tune, or nil if its tempo is believable (or it has
    /// none). `untypedOdd` is true for an impossible tempo with no type.
    static func check(uuid: UUID, title: String, type rawType: String, abc: String) -> (Finding?, untypedOdd: Bool) {
        let unified = abc.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = unified.components(separatedBy: "\n")
        guard let w = written(in: lines) else { return (nil, false) }
        let quarterBPM = Double(w.bpm) * 4 * Double(w.num) / Double(w.den)

        var type = rawType.trimmingCharacters(in: .whitespaces).lowercased()
        if type.isEmpty,
           let r = lines.first(where: { $0.hasPrefix("R:") }) {
            type = r.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard !type.isEmpty, let standard = TuneTypeDefaults.tempo(for: type) else {
            return (nil, quarterBPM < 20 || quarterBPM > 400)
        }
        guard let beat = countedBeat(meter: meter(in: lines), type: type) else { return (nil, false) }
        let counted = quarterBPM / (4 * Double(beat.num) / Double(beat.den))
        let low = Double(standard) * lowFactor, high = Double(standard) * highFactor
        guard counted < low || counted > high else { return (nil, false) }

        var q = "Q:"
        if let words = w.words, !words.isEmpty { q += "\"\(words)\" " }
        q += "\(beat.num)/\(beat.den)=\(standard)"
        lines[w.lineIndex] = q
        let finding = Finding(uuid: uuid, title: title, type: type,
                              written: Int(counted.rounded()), standard: standard,
                              beatName: beatName(beat),
                              before: abc, after: lines.joined(separator: "\n"))
        return (finding, false)
    }

    /// The whole library, worked out away from the screen from plain copies.
    public static func scan(_ tunes: [(uuid: UUID, title: String, type: String, abc: String)]) async -> Scan {
        await Task.detached(priority: .userInitiated) {
            var findings: [Finding] = []
            var untyped = 0
            for t in tunes where !t.abc.isEmpty {
                let (f, odd) = check(uuid: t.uuid, title: t.title, type: t.type, abc: t.abc)
                if let f { findings.append(f) }
                if odd { untyped += 1 }
            }
            findings.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return Scan(findings: findings, untypedOdd: untyped)
        }.value
    }

    /// The tidy's changes, for its backup and Undo.
    static func changes(_ findings: [Finding]) -> [LibraryTidy.Change] {
        findings.map { LibraryTidy.Change(uuid: $0.uuid, title: $0.title, before: $0.before, after: $0.after) }
    }
}

/// The page, shared by the iPhone, iPad and Mac.
public struct LibraryTempoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var tunes: [Tune]

    @State private var scan: LibraryTempo.Scan?
    @State private var backup = LibraryTidy.lastBackup(kind: LibraryTempo.backupKind)
    @State private var working = false
    @State private var message: String?
    @State private var confirmUndo = false
    @State private var stage: LibraryTidy.Stage?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Finds tunes whose written tempo is far from how that kind of tune is played — under half the usual speed, or more than half as fast again — and sets the usual tempo for the type instead. Speeds are counted the way a foot taps them: minims in a reel or hornpipe, dotted crotchets in a jig.")
                    Text("Only the tempo line changes. A backup is made first, and **Undo** puts every tune back. Your own practice speeds are not touched.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                Section("Your library") {
                    if let scan {
                        if scan.findings.isEmpty {
                            Label("No tune has an unrealistic tempo.", systemImage: "checkmark.circle")
                        } else {
                            Text("\(scan.findings.count) tunes have a tempo far from the usual for their type. Nothing changes until you press the button.")
                            Button {
                                fix(scan.findings)
                            } label: {
                                Label("Set the usual tempo for all \(scan.findings.count)", systemImage: "metronome")
                            }
                            .disabled(working)
                        }
                        if scan.untypedOdd > 0 {
                            Text("\(scan.untypedOdd) more have an impossible tempo but no tune type, so there's no usual tempo to give them. Give them a type, then look again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Looking through your tunes…").foregroundStyle(.secondary)
                        }
                    }
                }

                if let findings = scan?.findings, !findings.isEmpty {
                    Section("What would change") {
                        ForEach(findings) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(TitleDisplay.plain(f.title))
                                Text("\(f.type.capitalized): \(f.written) → \(f.standard) \(f.beatName) a minute")
                                    .font(.caption)
                                    .foregroundStyle(f.written > f.standard ? Color.orange : Color.blue)
                            }
                        }
                    }
                }

                if let stage {
                    Section("Working — please leave this page open") {
                        switch stage {
                        case .backingUp:
                            HStack { ProgressView().controlSize(.small); Text("Making the backup…") }
                        case .changing(let done, let total):
                            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                                Text("\(done) of \(total) tunes")
                            }
                        case .saving:
                            HStack { ProgressView().controlSize(.small); Text("Saving…") }
                        }
                    }
                }

                if let backup {
                    Section("Undo") {
                        Text("Changed the tempo of \(backup.count) tunes on \(backup.date.formatted(date: .abbreviated, time: .shortened)).")
                        Button(role: .destructive) {
                            confirmUndo = true
                        } label: {
                            Label("Undo the tempo changes", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(working)
                    }
                }

                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Check the tempos")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(working)
                }
            }
            .confirmationDialog("Put every changed tempo back as it was?",
                                isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("Undo the tempo changes", role: .destructive) { undo() }
            } message: {
                Text("Tunes you have edited since are left as they are.")
            }
            .task { await look() }
        }
        .interactiveDismissDisabled(working)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func look() async {
        scan = nil
        let copies = tunes.map { (uuid: $0.uuid, title: $0.title, type: $0.type, abc: $0.abc) }
        scan = await LibraryTempo.scan(copies)
    }

    private func fix(_ findings: [LibraryTempo.Finding]) {
        working = true
        message = nil
        Task { @MainActor in
            defer { working = false; stage = nil }
            do {
                backup = try await LibraryTidy.apply(LibraryTempo.changes(findings), context: context,
                                                     kind: LibraryTempo.backupKind) { stage = $0 }
                message = "Set the usual tempo for \(findings.count) tunes. Undo is above if you want them back."
                await look()
            } catch {
                message = "Nothing was changed: the backup couldn't be written (\(error.localizedDescription))."
            }
        }
    }

    private func undo() {
        guard let info = backup else { return }
        working = true
        message = nil
        Task { @MainActor in
            defer { working = false; stage = nil }
            do {
                let result = try await LibraryTidy.undo(info, context: context) { stage = $0 }
                message = "Put back \(result.restored) tunes."
                    + (result.kept > 0 ? " \(result.kept) edited since were left as they are." : "")
                backup = LibraryTidy.lastBackup(kind: LibraryTempo.backupKind)
                await look()
            } catch {
                message = "Couldn't undo: \(error.localizedDescription)"
            }
        }
    }
}
