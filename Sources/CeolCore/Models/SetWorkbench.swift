import Foundation
import SwiftData

/// Building a set by choosing tunes, rather than by following the circle.
///
/// This is a *second* way of building a set, not a replacement for the wheel.
/// The circle-of-fifths builder answers "what goes well after this?" and leads
/// with key relationships. This one answers "show me my three-star reels in G
/// and let me pick" — the filters lead, and you decide.
///
/// The state lives here rather than in either app's view so the two cannot
/// drift on what a filter means or what order things end up in. The views own
/// the layout and nothing else.
public struct SetWorkbench {

    /// The running order, in order. Duplicates are allowed — a set that comes
    /// back round to its first tune is a real thing and refusing it would be
    /// the app being cleverer than the music.
    public private(set) var running: [Tune] = []

    /// Type, key and rating. The same `TuneFilter` the library uses, so "reel"
    /// and "G major" mean here exactly what they mean there.
    public var filter = TuneFilter()
    /// Searching by name, which the library's filter has no notion of.
    public var search = ""

    public init(startingWith tune: Tune? = nil) {
        if let tune { running = [tune] }
    }

    // MARK: - The running order

    public var isEmpty: Bool { running.isEmpty }
    public var count: Int { running.count }

    public mutating func add(_ tune: Tune) { running.append(tune) }

    public mutating func remove(at index: Int) {
        guard running.indices.contains(index) else { return }
        running.remove(at: index)
    }

    public mutating func remove(_ tune: Tune) {
        if let index = running.firstIndex(where: { $0 === tune }) { running.remove(at: index) }
    }

    /// Move by whole positions, which is what a set is: first, second, third.
    /// SwiftUI's `onMove` hands an `IndexSet` and a destination, so that shape
    /// is offered as well.
    public mutating func move(from source: IndexSet, to destination: Int) {
        running.move(fromOffsets: source, toOffset: destination)
    }

    public mutating func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard running.indices.contains(index), running.indices.contains(target) else { return }
        running.swapAt(index, target)
    }

    // MARK: - What to offer next

    /// Tunes worth showing, given the filters and what is already chosen.
    ///
    /// The set's own tunes are not excluded from the list, only marked — see
    /// `alreadyIn`. Hiding them would make a tune vanish the moment you added
    /// it, which reads as the app having lost it.
    public func candidates(from tunes: [Tune], media: MediaIndex? = nil) -> [Tune] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = query.isEmpty ? nil : TitleMatching.normalise(query)
        return tunes.filter { tune in
            // One version per group. The library shows the default and so
            // should this — offering four settings of Calliope House as four
            // separate candidates is noise, and the version can be changed
            // afterwards on the set itself.
            if tune.groupID != nil && !tune.isDefaultVersion { return false }
            guard filter.matches(tune, media: media) else { return false }
            guard let normalised else { return true }
            if TitleMatching.normalise(tune.title).contains(normalised) { return true }
            return tune.aliases.contains { TitleMatching.normalise($0).contains(normalised) }
        }
    }

    public func alreadyIn(_ tune: Tune) -> Bool {
        running.contains { $0 === tune }
    }

    /// Type-ahead: the few best matches for what has been typed so far.
    ///
    /// Ignores the filters deliberately. This is the "I already know what I
    /// want" route, and having a tune refuse to appear because a filter you
    /// set ten minutes ago excludes it would be baffling.
    public static func matches(_ text: String, in tunes: [Tune], limit: Int = 8) -> [Tune] {
        let query = TitleMatching.normalise(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard query.count >= 2 else { return [] }
        var starts: [Tune] = []
        var contains: [Tune] = []
        for tune in tunes {
            if tune.groupID != nil && !tune.isDefaultVersion { continue }
            let title = TitleMatching.normalise(tune.title)
            if title.hasPrefix(query) { starts.append(tune) }
            else if title.contains(query) { contains.append(tune) }
            else if tune.aliases.contains(where: { TitleMatching.normalise($0).contains(query) }) {
                contains.append(tune)
            }
            if starts.count >= limit { break }
        }
        let ordered = starts.sorted { TitleDisplay.precedes($0.title, $1.title) }
            + contains.sorted { TitleDisplay.precedes($0.title, $1.title) }
        return Array(ordered.prefix(limit))
    }

    // MARK: - Describing itself

    /// A name to suggest: the tunes' own names, as a set is usually called.
    public var suggestedName: String {
        guard !running.isEmpty else { return "" }
        let names = running.prefix(3).map { TitleDisplay.spoken($0.title) }
        return names.joined(separator: " / ")
    }

    /// "Three reels in G" — what this actually is, for the header.
    public var shape: String {
        guard !running.isEmpty else { return "Nothing chosen yet" }
        let types = Set(running.map { $0.type.lowercased() }.filter { !$0.isEmpty })
        let keys = Set(running.map(\.displayKey).filter { !$0.isEmpty })
        var text = running.count == 1 ? "1 tune" : "\(running.count) tunes"
        if types.count == 1, let type = types.first {
            text = running.count == 1 ? "1 \(type)" : "\(running.count) \(type)s"
        }
        if keys.count == 1, let key = keys.first { text += " in \(key)" }
        return text
    }

    // MARK: - Saving

    /// Write the set. Returns nil when there is nothing to write.
    @discardableResult
    @MainActor
    public func save(as name: String, in context: ModelContext) -> TuneSet? {
        guard !running.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let set = TuneSet(name: trimmed.isEmpty ? suggestedName : trimmed)
        context.insert(set)
        for (position, tune) in running.enumerated() {
            let entry = SetEntry(position: position, tune: tune)
            entry.tuneSet = set
            context.insert(entry)
        }
        try? context.save()
        return set
    }

    /// The notation of the whole running order, for the preview player.
    ///
    /// One ABC document per tune, in order — the same thing the set screen
    /// plays, so what you hear while building is what you get afterwards.
    public var previewABC: [String] {
        running.map(\.abc).filter { !$0.isEmpty }
    }
}
