import Foundation
import SwiftUI
import SwiftData

// FONN-LIBTIDY-1
/// Lays out the whole library afresh with `ABCLayout.phrased` (four bars a
/// line, a new line for each part, part labels), and puts it back exactly as
/// it was if asked.
///
/// Before anything is changed, every tune's ABC as it was, and as it will be,
/// is written to a backup file in the app's own storage. Undo reads that file
/// and puts back the old ABC of each tune that still holds the tidied ABC; a
/// tune edited since is left alone and counted, so Undo never throws away
/// later work. The file can also be shared or saved from the same page. iCloud
/// carries the changed tunes, and an undo, to the other devices like any edit.
///
/// Also here: the switch for tidying tunes as they are imported
/// (`ABCLayout.onImport`), on unless turned off.
public enum LibraryTidy {

    public struct Change: Sendable {
        public let uuid: UUID
        public let title: String
        public let before: String
        public let after: String
    }

    struct Saved: Codable {
        let uuid: UUID
        let title: String
        let before: String
        let after: String
    }

    struct Backup: Codable {
        let date: Date
        var undone: Bool
        let items: [Saved]
    }

    public struct BackupInfo: Equatable {
        public let url: URL
        public let date: Date
        public let count: Int
    }

    /// Which tunes the tidy would change, worked out away from the screen.
    /// Takes plain copies of the ABC, so the tunes themselves stay on the
    /// main actor.
    public static func changes(of tunes: [(uuid: UUID, title: String, abc: String)]) async -> [Change] {
        await Task.detached(priority: .userInitiated) {
            tunes.compactMap { t -> Change? in
                guard !t.abc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let after = ABCLayout.phrased(t.abc)
                let same = after.trimmingCharacters(in: .whitespacesAndNewlines)
                    == t.abc.trimmingCharacters(in: .whitespacesAndNewlines)
                return same ? nil : Change(uuid: t.uuid, title: t.title, before: t.abc, after: after)
            }
        }.value
    }

    /// FONN-TEMPOCHECK-1: each tool that changes the whole library keeps its
    /// backups in a folder of its own, so one tool's Undo never finds the
    /// other's. "LayoutTidy" is the layout tidy's.
    public static let layoutKind = "LayoutTidy"

    static func folder(_ kind: String = layoutKind) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(kind, isDirectory: true)
    }

    /// The most recent tidy that hasn't been undone, if there is one.
    public static func lastBackup(kind: String = layoutKind) -> BackupInfo? {
        let dir = Self.folder(kind)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let backups = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Backup)? in
            guard let data = try? Data(contentsOf: url),
                  let b = try? JSONDecoder.tidy.decode(Backup.self, from: data) else { return nil }
            return (url, b)
        }
        guard let last = backups.filter({ !$0.1.undone }).max(by: { $0.1.date < $1.1.date }) else { return nil }
        return BackupInfo(url: last.0, date: last.1.date, count: last.1.items.count)
    }

    /// Writes the backup, then the tidied ABC. If the backup can't be
    /// written, nothing is changed.
    /// FONN-TIDYPROGRESS-1: where a tidy or an undo has got to, for the page
    /// to show. Over a thousand tunes the work takes long enough that a page
    /// saying nothing reads as a hang, and gets closed halfway.
    public enum Stage: Equatable {
        case backingUp
        case changing(done: Int, of: Int)
        case saving
    }

    /// Writes the backup, then the tidied ABC. If the backup can't be
    /// written, nothing is changed.
    ///
    /// In steps, pausing every few tunes so the page can redraw its progress:
    /// the models live on the main actor, so the work can't move off it, but
    /// it can stop hogging it.
    @MainActor
    public static func apply(_ changes: [Change], context: ModelContext,
                             kind: String = layoutKind,
                             progress: @MainActor (Stage) -> Void = { _ in }) async throws -> BackupInfo {
        let dir = Self.folder(kind)
        progress(.backingUp)
        await breathe()
        let date = Date.now
        let backup = Backup(date: date, undone: false,
                            items: changes.map { Saved(uuid: $0.uuid, title: $0.title, before: $0.before, after: $0.after) })
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let label = kind == layoutKind ? "layout tidy" : "tempo check"
        let url = dir.appendingPathComponent("Fonn \(label) \(stamp).json")
        try JSONEncoder.tidy.encode(backup).write(to: url, options: .atomic)

        let wanted = Dictionary(changes.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let tunes = ((try? context.fetch(FetchDescriptor<Tune>())) ?? []).filter { wanted[$0.uuid] != nil }
        for (index, tune) in tunes.enumerated() {
            if let change = wanted[tune.uuid], tune.abc == change.before { tune.abc = change.after }
            if index % 20 == 0 {
                progress(.changing(done: index, of: tunes.count))
                await breathe()
            }
        }
        progress(.changing(done: tunes.count, of: tunes.count))
        progress(.saving)
        await breathe()
        try context.save()
        return BackupInfo(url: url, date: date, count: changes.count)
    }

    /// A moment's pause on the main actor, so SwiftUI can draw.
    @MainActor
    private static func breathe() async {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }

    /// Puts back the ABC the tidy replaced. Returns how many tunes were put
    /// back and how many were left because they have been edited since.
    @MainActor
    public static func undo(_ info: BackupInfo, context: ModelContext,
                            progress: @MainActor (Stage) -> Void = { _ in }) async throws -> (restored: Int, kept: Int) {
        var backup = try JSONDecoder.tidy.decode(Backup.self, from: Data(contentsOf: info.url))
        let saved = Dictionary(backup.items.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        var restored = 0, kept = 0
        let tunes = ((try? context.fetch(FetchDescriptor<Tune>())) ?? []).filter { saved[$0.uuid] != nil }
        for (index, tune) in tunes.enumerated() {
            guard let item = saved[tune.uuid] else { continue }
            if tune.abc == item.after {
                tune.abc = item.before
                restored += 1
            } else if tune.abc != item.before {
                kept += 1
            }
            if index % 20 == 0 {
                progress(.changing(done: index, of: tunes.count))
                await breathe()
            }
        }
        progress(.changing(done: tunes.count, of: tunes.count))
        progress(.saving)
        await breathe()
        try context.save()
        backup.undone = true
        try JSONEncoder.tidy.encode(backup).write(to: info.url, options: .atomic)
        return (restored, kept)
    }
}

extension JSONEncoder {
    static var tidy: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var tidy: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension ABCLayout {
    /// FONN-LIBTIDY-1: the setting, kept per device.
    public static let tidyOnImportKey = "fonn.tidyOnImport"

    /// ABC arriving from outside Fonn (thesession.org, an .abc or MusicXML
    /// file, FolkFriend) laid out like the rest of the library, unless the
    /// setting is off. Fonn's own files (.fonn, .ceol.json) are not passed
    /// through this, so a backup comes back exactly as it was saved.
    public static func onImport(_ abc: String) -> String {
        let on = UserDefaults.standard.object(forKey: tidyOnImportKey) as? Bool ?? true
        guard on, !abc.isEmpty else { return abc }
        return phrased(abc)
    }
}

/// FONN-TIDYSCOPE-1: which tunes a tidy covers, when it isn't the whole
/// library: one tune, a selection, or a collection. Every version of each
/// tune comes too, so the tune looks the same whichever version is showing.
public struct TidyScope: Identifiable {
    public let id = UUID()
    public let name: String
    let tuneIDs: Set<UUID>
    let groupIDs: Set<UUID>

    public init(name: String, tunes: [Tune]) {
        self.name = name
        tuneIDs = Set(tunes.map(\.uuid))
        groupIDs = Set(tunes.compactMap(\.groupID))
    }

    func covers(_ tune: Tune) -> Bool {
        if tuneIDs.contains(tune.uuid) { return true }
        if let g = tune.groupID { return groupIDs.contains(g) }
        return false
    }
}

/// The page: what the tidy does, how many tunes it would change, Tidy,
/// Undo, and the import switch. Shared by the iPhone, iPad and Mac.
public struct LibraryTidyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allTunes: [Tune]
    /// FONN-TIDYSCOPE-1: nil is the whole library.
    private let scope: TidyScope?

    private var tunes: [Tune] {
        guard let scope else { return allTunes }
        return allTunes.filter { scope.covers($0) }
    }
    @AppStorage(ABCLayout.tidyOnImportKey) private var tidyOnImport = true

    @State private var pending: [Change]?
    @State private var backup = LibraryTidy.lastBackup()
    @State private var working = false
    @State private var message: String?
    @State private var confirmUndo = false
    @State private var stage: LibraryTidy.Stage?   // FONN-TIDYPROGRESS-1

    typealias Change = LibraryTidy.Change

    public init(scope: TidyScope? = nil) {
        self.scope = scope
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Lays out every tune the same way: four bars to a line, so each phrase sits under the one before and repeats line up; each part on new lines; and A, B, C at the start of each part where the tune doesn't name them already. Old-style ! line breaks, blank lines and hidden characters go too.")
                    Text("No note changes. A backup is made first, and **Undo** puts every tune back exactly as it was.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                Section(scope?.name ?? "Your library") {
                    if let pending {
                        if pending.isEmpty {
                            Label(scope == nil ? "Every tune is already laid out this way."
                                               : "These are already laid out this way.",
                                  systemImage: "checkmark.circle")
                        } else {
                            Text(scope == nil
                                 ? "\(pending.count) of your \(tunes.count) tunes would change. Press the button below to tidy them all; nothing happens until you do."
                                 : "\(pending.count) of these \(tunes.count) tunes and versions would change. Press the button below to tidy them; nothing happens until you do.")
                            Text(pending.prefix(4).map(\.title).joined(separator: ", ")
                                 + (pending.count > 4 ? " …" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                tidy(pending)
                            } label: {
                                Label(pending.count == 1 ? "Tidy it now" : "Tidy all \(pending.count) now",
                                      systemImage: "wand.and.stars")
                            }
                            .disabled(working)
                        }
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Looking through your tunes…").foregroundStyle(.secondary)
                        }
                    }
                }

                if let stage {
                    Section("Working — please leave this page open") {
                        switch stage {
                        case .backingUp:
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Making the backup…")
                            }
                        case .changing(let done, let total):
                            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                                Text("\(done) of \(total) tunes")
                            }
                        case .saving:
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Saving…")
                            }
                        }
                    }
                }

                if let backup {
                    Section("Undo") {
                        Text("Tidied \(backup.count) tunes on \(backup.date.formatted(date: .abbreviated, time: .shortened)).")
                        Button(role: .destructive) {
                            confirmUndo = true
                        } label: {
                            Label("Undo the tidy", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(working)
                        ShareLink(item: backup.url) {
                            Label("Save a copy of the backup", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section {
                    Toggle("Also tidy new tunes as they're imported", isOn: $tidyOnImport)
                } footer: {
                    Text("Tunes from thesession.org, ABC and MusicXML files and FolkFriend are laid out the same way as they arrive. Fonn files and backups come in exactly as they were saved.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(scope == nil ? "Tidy the layout" : "Tidy: \(scope?.name ?? "")")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(working)
                }
            }
            .confirmationDialog("Put every tidied tune back as it was?",
                                isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("Undo the tidy", role: .destructive) { undo() }
            } message: {
                Text("Tunes you have edited since the tidy are left as they are.")
            }
            .task { await look() }
        }
        .interactiveDismissDisabled(working)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private func look() async {
        pending = nil
        let copies = tunes.map { (uuid: $0.uuid, title: $0.title, abc: $0.abc) }
        pending = await LibraryTidy.changes(of: copies)
    }

    private func tidy(_ changes: [Change]) {
        working = true
        message = nil
        Task { @MainActor in
            defer { working = false; stage = nil }
            do {
                backup = try await LibraryTidy.apply(changes, context: context) { stage = $0 }
                message = "Tidied \(changes.count) tunes. Undo is above if you want them back."
                pending = []
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
                    + (result.kept > 0 ? " \(result.kept) edited since the tidy were left as they are." : "")
                backup = LibraryTidy.lastBackup()
                await look()
            } catch {
                message = "Couldn't undo: \(error.localizedDescription)"
            }
        }
    }
}
