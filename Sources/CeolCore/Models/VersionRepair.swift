import Foundation
import SwiftData

/// Puts version groups back into a state the rest of the app can read.
///
/// Every list in Fonn shows one row per tune by hiding the non-default
/// settings of a group. That rule has an unstated assumption: **every group has
/// exactly one default**. When it doesn't, the consequences are silent and
/// severe in opposite directions —
///
/// - *no* default and every member is hidden, so the tune vanishes from the
///   library altogether. Not from the data; from the list. It is still there,
///   still in its sets and collections, and there is no way to find it by
///   looking;
/// - *two* defaults and the tune appears twice, which is the complaint that
///   led here.
///
/// Found on 3 September in a library of 1,784 records: 409 groups, of which 75
/// had no default at all. Harvest Home, Soldier's Joy, Jacky Tar and The High
/// Road To Linton were among the tunes that were simply not in the library any
/// more as far as the app was concerned.
///
/// ## Where it came from
///
/// The merge on 2 September. Two libraries had been grouped independently, and
/// merging by record identity kept both sets of grouping. It is not a bug that
/// can be caught at the point of grouping, because each group was valid when it
/// was made — they only became wrong beside each other.
///
/// ## Why this is a button and not a launch task
///
/// It ran at every launch for exactly one build, and that was a mistake twice
/// over. It fetches the whole library and rewrites up to a hundred records on
/// the main actor, which with CloudKit mirroring behind it left the app
/// unresponsive on a real library of 1,784 tunes. And it changes what is in
/// front of the reader — un-hiding 75 tunes, many of which are the other half
/// of a title that is split across two groups, so they arrive looking exactly
/// like fresh duplicates.
///
/// Both are fine as an answer to "yes, do that now". Neither is acceptable as
/// something the app does to somebody while they are trying to open it.
///
/// It also no longer repoints set entries. Marking a default is enough to bring
/// a hidden tune back; moving every set that used a sibling setting onto the
/// newly-chosen one is a much larger change, it is not needed for the fix, and
/// it is not reversible. `VersionTools.makeDefault` still does it, because
/// there it is what the reader asked for.
public enum VersionRepair {

    public struct Outcome: Sendable, Equatable {
        /// Groups that had no default and now have one.
        public let promoted: [String]
        /// Groups that had more than one and now have one.
        public let demoted: [String]

        public var changed: Bool { !promoted.isEmpty || !demoted.isEmpty }

        public var summary: String {
            guard changed else { return "Every version group has one default setting." }
            var parts: [String] = []
            if !promoted.isEmpty {
                parts.append(promoted.count == 1
                    ? "1 tune was hidden by a version group with no default setting and is back in the library."
                    : "\(promoted.count) tunes were hidden by version groups with no default setting and are back in the library.")
            }
            if !demoted.isEmpty {
                parts.append(demoted.count == 1
                    ? "1 group had two default settings and now has one."
                    : "\(demoted.count) groups had more than one default setting and now have one.")
            }
            return parts.joined(separator: " ")
        }
    }

    private static let outcomeKey = "ceol.versions.lastRepair"

    /// What the last run did, for the Settings screen.
    public static var lastOutcome: String? {
        UserDefaults.standard.string(forKey: outcomeKey)
    }

    /// After settings have been moved out of their old groups, make sure none
    /// of those groups was left without a default.
    ///
    /// This is the sharp end of the whole problem. Grouping moves the chosen
    /// settings to a new group id and marks them; the members left behind keep
    /// the old id and their old flags. If the setting that moved was the old
    /// group's default, what remains is a group with no default — and that
    /// hides every one of its settings, so a tune the reader never touched
    /// disappears from the library.
    ///
    /// Silent, delayed, and caused by an unrelated action: the worst shape a
    /// bug can have. Both grouping routines now call this, so neither can leave
    /// one behind.
    ///
    /// Narrow on purpose — only the named groups are examined, so it costs one
    /// fetch and never rewrites anything the reader did not just touch.
    @MainActor
    public static func heal(groups ids: Set<UUID>, in context: ModelContext) {
        guard !ids.isEmpty else { return }
        let all = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        var touched = false
        for id in ids {
            let members = all.filter { $0.groupID == id }
            guard !members.isEmpty,
                  !members.contains(where: \.isDefaultVersion),
                  let heir = steadiest(of: members) else { continue }
            heir.isDefaultVersion = true
            touched = true
        }
        if touched { try? context.save() }
    }

    /// Give every version group exactly one default setting.
    @discardableResult
    @MainActor
    public static func run(in context: ModelContext) -> Outcome {
        let all = (try? context.fetch(FetchDescriptor<Tune>())) ?? []

        var groups: [UUID: [Tune]] = [:]
        for tune in all {
            guard let id = tune.groupID else { continue }
            groups[id, default: []].append(tune)
        }

        var promoted: [String] = []
        var demoted: [String] = []

        for (_, members) in groups {
            let defaults = members.filter(\.isDefaultVersion)
            if defaults.count == 1 { continue }

            // Only the flag. Nothing here touches sets — see the note above.
            if defaults.isEmpty {
                guard let pick = steadiest(of: members) else { continue }
                pick.isDefaultVersion = true
                promoted.append(pick.title)
            } else {
                guard let keep = steadiest(of: defaults) else { continue }
                for other in defaults where other !== keep {
                    other.isDefaultVersion = false
                }
                demoted.append(keep.title)
            }
        }

        let outcome = Outcome(promoted: promoted.sorted(), demoted: demoted.sorted())
        if outcome.changed {
            try? context.save()
            UserDefaults.standard.set(outcome.summary, forKey: outcomeKey)
        }
        return outcome
    }

    /// Which setting to make the default.
    ///
    /// Notation first, because a setting with no ABC is one you cannot read or
    /// play, and making it the face of the tune would be a poor choice made on
    /// the reader's behalf. Then the oldest, which is the one that was in the
    /// library before any of the versioning happened — the setting they have
    /// been looking at all along.
    ///
    /// It is a guess either way, and a cheap one to overrule: the Versions
    /// panel changes the default in one tap.
    private static func steadiest(of members: [Tune]) -> Tune? {
        let readable = members.filter {
            !$0.abc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let pool = readable.isEmpty ? members : readable
        return pool.min { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.title < b.title
        }
    }
}
