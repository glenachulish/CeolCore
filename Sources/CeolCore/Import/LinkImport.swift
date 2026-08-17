import Foundation
import SwiftData

/// Turn the web addresses sitting in notes into real attachments.
///
/// The Pi never had attachments for links. It re-read the notes on every render
/// — `_refreshSheetMusicMediaButtons` in `app.js` scans `t.all_notes` with one
/// regular expression each time a tune is drawn — and built the play buttons
/// from whatever it found. That works in a browser, where re-running a regex
/// over a paragraph costs nothing and nothing else needs to know.
///
/// It does not work here. A filter cannot scan 1,500 notes fields on every
/// keystroke; the media panel, the version-group logic and the "has a link"
/// filter are all built on `MediaItem`; and a URL that is only ever text can
/// never be given a title, played at half speed, or removed. So the addresses
/// are promoted once, and after that they are ordinary attachments.
///
/// The Mac already offered this one link at a time, with a Save button beside
/// each. That is the right thing for a link you have just noticed and the wrong
/// thing for 55 of them.
public enum LinkImport {

    /// One address that could become an attachment.
    public struct Candidate: Identifiable, Hashable, Sendable {
        public let id: String
        public let url: String
        public let ownerTitle: String
        public let kind: MediaKind
        /// A tune, or a set — both keep notes and both collected links.
        public let owner: PersistentIdentifier
        public let isSet: Bool

        init(url: URL, ownerTitle: String, kind: MediaKind,
             owner: PersistentIdentifier, isSet: Bool) {
            self.id = "\(owner.hashValue)|\(url.absoluteString)"
            self.url = url.absoluteString
            self.ownerTitle = ownerTitle
            self.kind = kind
            self.owner = owner
            self.isSet = isSet
        }
    }

    public struct Plan: Sendable {
        public var candidates: [Candidate] = []
        /// Addresses skipped because they only ever resolved on the machine
        /// that wrote them — `localhost:8001` and the Pi's own Tailscale name.
        /// Eleven of this library's links are these. They look like recordings
        /// and are dead everywhere, so promoting them would mean 11 attachments
        /// that can only ever fail.
        public var deadLocal = 0

        public var isEmpty: Bool { candidates.isEmpty }

        public var summary: String {
            guard !candidates.isEmpty else {
                return deadLocal > 0
                    ? "No links to add. \(deadLocal) point at the Pi itself and would never play."
                    : "Every link in your notes is already an attachment."
            }
            let tunes = Set(candidates.filter { !$0.isSet }.map(\.owner)).count
            let sets = Set(candidates.filter(\.isSet).map(\.owner)).count
            var where_ = "\(tunes) tune\(tunes == 1 ? "" : "s")"
            if sets > 0 { where_ += " and \(sets) set\(sets == 1 ? "" : "s")" }
            var text = "\(candidates.count) link\(candidates.count == 1 ? "" : "s") across \(where_)."
            if deadLocal > 0 { text += " \(deadLocal) skipped — they point at the Pi itself." }
            return text
        }
    }

    /// What would be added, without adding it.
    @MainActor
    public static func plan(in context: ModelContext) -> Plan {
        var plan = Plan()

        func consider(notes: String, title: String, existing: Set<String>,
                      owner: PersistentIdentifier, isSet: Bool) {
            for url in LinkedText.urls(in: notes) {
                // The Pi wrote its own address into the notes for every
                // uploaded file. Those are fetched as files by `PiBridge`, not
                // kept as links — a link to `/api/uploads/x.mp3` is useless the
                // moment you are away from the Pi.
                if MediaLinks.isLocalOnly(url) { plan.deadLocal += 1; continue }
                let secured = MediaLinks.secured(url)
                guard !existing.contains(secured.absoluteString),
                      !existing.contains(url.absoluteString) else { continue }
                plan.candidates.append(Candidate(url: secured,
                                                 ownerTitle: title,
                                                 kind: kind(of: secured),
                                                 owner: owner,
                                                 isSet: isSet))
            }
        }

        for tune in (try? context.fetch(FetchDescriptor<Tune>())) ?? [] {
            guard tune.notes.contains("http") else { continue }
            let existing = Set((tune.media ?? []).map(\.urlString).filter { !$0.isEmpty })
            consider(notes: tune.notes, title: tune.title, existing: existing,
                     owner: tune.persistentModelID, isSet: false)
        }
        for set in (try? context.fetch(FetchDescriptor<TuneSet>())) ?? [] {
            guard set.notes.contains("http") else { continue }
            let existing = Set((set.media ?? []).map(\.urlString).filter { !$0.isEmpty })
            consider(notes: set.notes, title: set.name, existing: existing,
                     owner: set.persistentModelID, isSet: true)
        }

        // Deduplicated on the way in by `id`, but the same address can appear
        // twice in one notes field.
        var seen = Set<String>()
        plan.candidates = plan.candidates.filter { seen.insert($0.id).inserted }
        plan.candidates.sort {
            $0.ownerTitle.localizedCaseInsensitiveCompare($1.ownerTitle) == .orderedAscending
        }
        return plan
    }

    /// Where a link goes in the media list.
    ///
    /// `.link` for a page to open — YouTube included, because the player is a
    /// web view either way and `MediaLinks.youTubeID` is what decides how it is
    /// shown. `.audio` only for a direct file, which can be played with the
    /// same speed control as a recording on disk.
    private static func kind(of url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg"].contains(ext) {
            return .audio
        }
        if ["mp4", "mov", "webm", "m4v"].contains(ext) { return .video }
        return .link
    }

    /// A readable name, so the list does not read as a column of URLs.
    private static func title(for url: URL) -> String {
        if MediaLinks.youTubeID(of: url) != nil { return "YouTube" }
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        if host.isEmpty { return "Link" }
        return host.split(separator: ".").first.map(String.init)?.capitalized ?? host
    }

    @discardableResult
    @MainActor
    public static func apply(_ plan: Plan, in context: ModelContext) -> Int {
        var added = 0
        for candidate in plan.candidates {
            guard let url = URL(string: candidate.url) else { continue }
            let item = MediaItem(kind: candidate.kind,
                                 title: title(for: url),
                                 urlString: candidate.url)
            if candidate.isSet {
                // No `updatedAt` on TuneSet — only `createdAt`. Nothing to
                // touch, rather than adding a column for the sake of symmetry.
                guard let set = context.model(for: candidate.owner) as? TuneSet else { continue }
                item.tuneSet = set
            } else {
                guard let tune = context.model(for: candidate.owner) as? Tune else { continue }
                item.tune = tune
                tune.updatedAt = Date()
            }
            context.insert(item)
            added += 1
        }
        try? context.save()
        return added
    }
}
