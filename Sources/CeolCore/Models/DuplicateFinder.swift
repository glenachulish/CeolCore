import Foundation
import SwiftData

/// Finding tunes that are the same tune, and linking them as versions.
///
/// Ported from the Fonn web app, where it began: exact groups by normalised
/// title — so that "The Road to Banff", "Road to Banff, The" and
/// "01 - Road to Banff" land together — plus fuzzy suggestions for titles that
/// share more than half their meaningful words.
///
/// Here rather than in a view because it is arithmetic, not interface, and
/// because both apps want it. (The iPhone's `DuplicatesView` still carries its
/// own copy of these five functions; they are identical, and folding it onto
/// this one is a mechanical change worth doing when that file is next open.)
public enum DuplicateFinder {

    // MARK: - Titles

    /// Port of the web app's `_normalize_title_for_grouping`.
    public static func normalisedTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespaces).lowercased()
        // Leading track numbers: "01 ", "01 - ", "1. " — but keep "1st".
        t = t.replacingOccurrences(
            of: #"^\d+(?!st|nd|rd|th)[\s\-_\.]+"#, with: "", options: .regularExpression)
        for (suffix, prefix) in [(", the", "the "), (", a", "a "), (", an", "an ")] {
            if t.hasSuffix(suffix) {
                t = prefix + t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        for article in ["the ", "a ", "an "] {
            if t.hasPrefix(article) { t = String(t.dropFirst(article.count)); break }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The words that carry meaning for similarity. Rhythm names are stop
    /// words: half the library would otherwise look like half the library
    /// because both titles contain "reel".
    public static func meaningfulWords(_ title: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "of", "to", "and", "in", "on", "no", "reel",
                                 "jig", "polka", "hornpipe", "march", "waltz", "set"]
        let cleaned = normalisedTitle(title)
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
        return Set(cleaned.split(separator: " ").map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Stable across the order the two were found in, so a pair dismissed once
    /// stays dismissed.
    public static func pairKey(_ a: Tune, _ b: Tune) -> String {
        [a.uuid.uuidString, b.uuid.uuidString].sorted().joined(separator: "|")
    }

    // MARK: - What was found

    public struct Group: Identifiable {
        public let id: String
        public let title: String
        public let tunes: [Tune]
    }

    public struct Suggestion: Identifiable {
        public let id: String
        public let a: Tune
        public let b: Tune
        public let similarity: Double
    }

    /// Tunes already grouped as versions are not candidates — dealing with a
    /// group is what takes it off this list.
    private static func candidates(_ tunes: [Tune]) -> [Tune] {
        tunes.filter { $0.groupID == nil && !$0.title.isEmpty }
    }

    public static func exactGroups(in tunes: [Tune]) -> [Group] {
        var buckets: [String: [Tune]] = [:]
        for tune in candidates(tunes) {
            buckets[normalisedTitle(tune.title), default: []].append(tune)
        }
        return buckets.compactMap { key, group in
            guard group.count > 1 else { return nil }
            return Group(id: key, title: group[0].title, tunes: group)
        }
        .sorted { TitleDisplay.precedes($0.title, $1.title) }
    }

    /// A word-bucket scan rather than comparing every pair against every other.
    /// With 1,500 tunes the all-pairs version is over a million comparisons and
    /// the screen takes seconds to appear; this only compares tunes that share
    /// at least one meaningful word.
    public static func suggestions(in tunes: [Tune],
                                   dismissed: Set<String> = []) -> [Suggestion] {
        let exactKeys = Set(exactGroups(in: tunes).map(\.id))
        let pool = candidates(tunes).filter { !exactKeys.contains(normalisedTitle($0.title)) }

        var words: [PersistentIdentifier: Set<String>] = [:]
        var buckets: [String: [Tune]] = [:]
        for tune in pool {
            let w = meaningfulWords(tune.title)
            guard !w.isEmpty else { continue }
            words[tune.persistentModelID] = w
            for word in w { buckets[word, default: []].append(tune) }
        }

        var seen = Set<String>()
        var result: [Suggestion] = []
        for (_, group) in buckets where group.count > 1 {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let a = group[i], b = group[j]
                    guard let wa = words[a.persistentModelID],
                          let wb = words[b.persistentModelID] else { continue }
                    let id = pairKey(a, b)
                    guard !seen.contains(id), !dismissed.contains(id) else { continue }
                    let similarity = Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
                    guard similarity > 0.5 else { continue }
                    seen.insert(id)
                    result.append(Suggestion(id: id, a: a, b: b, similarity: similarity))
                }
            }
        }
        return result.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Saying they are the same tune

    /// Link these tunes as versions of one another.
    ///
    /// Nothing is deleted and nothing is merged: every setting is kept, gets a
    /// label of its own ("Setting 2 · Ador"), and one of them — the first with
    /// real notation — becomes the one the library lists and the sets play.
    /// That is the whole reason this is safe to press.
    @discardableResult
    public static func group(_ tunes: [Tune], in context: ModelContext) -> Bool {
        guard tunes.count > 1 else { return false }
        let groupID = UUID()
        let chosen = tunes.first { !$0.abc.trimmingCharacters(in: .whitespaces).isEmpty } ?? tunes[0]
        for (i, tune) in tunes.enumerated() {
            let keyPart = tune.displayKey.isEmpty ? "" : " · \(tune.displayKey)"
            tune.versionLabel = "Setting \(i + 1)\(keyPart)"
            tune.groupID = groupID
            tune.isDefaultVersion = (tune === chosen)
            tune.updatedAt = Date()
        }
        // Any set using a non-default version now points at the default.
        VersionTools.pointSetsAtDefault(of: chosen, in: tunes)
        try? context.save()
        return true
    }
}
