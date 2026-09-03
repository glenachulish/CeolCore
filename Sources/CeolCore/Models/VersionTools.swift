import Foundation
import SwiftData

/// Helpers for tunes that are grouped as versions (settings) of one another.
public enum VersionTools {

    /// Save transposed notation as a new version of the same tune.
    ///
    /// The ABC handed in has already been rewritten by abcjs — real note
    /// letters and a real key signature — so the new version is a tune in its
    /// own right, not one that only reads correctly while a display setting
    /// happens to be applied. Its own transpose is therefore zero.
    ///
    /// The original stays the default: you transposed it to try something, and
    /// silently changing what your sets play would be a nasty surprise.
    @discardableResult
    public static func saveTransposed(_ source: Tune, abc: String, steps: Int,
                               in context: ModelContext) -> Tune {
        let sounding = soundingKey(of: source, shiftedBy: steps)
        let interval = steps > 0 ? "+\(steps)" : "\(steps)"
        let describe = sounding.isEmpty ? "\(interval) semitones" : "to \(sounding)"

        let copy = Tune(title: "\(source.title) transposed \(describe)",
                        type: source.type,
                        key: sounding.isEmpty ? source.key : sounding,
                        mode: source.mode,
                        abc: abc)
        copy.composer = source.composer
        copy.transcribedBy = source.transcribedBy
        copy.aliases = source.aliases
        copy.notes = source.notes
        copy.sourceURL = source.sourceURL
        copy.theSessionID = source.theSessionID
        copy.versionLabel = "Transposed \(describe)"
        copy.transpose = 0

        // Join the source's group, or start one containing both.
        let groupID = source.groupID ?? UUID()
        source.groupID = groupID
        copy.groupID = groupID
        copy.isDefaultVersion = false
        if !(versions(of: source, in: context).contains { $0.isDefaultVersion }) {
            source.isDefaultVersion = true
        }

        context.insert(copy)
        try? context.save()
        return copy
    }

    // MARK: - Saving an edit

    /// What came of saving an edit as a new version, for the app to report.
    ///
    /// `setsRepointed` is counted *before* the new version becomes the default,
    /// because after that the entries have already moved and there is nothing
    /// left to count. It is the number the user most wants: an edit that
    /// quietly changed what four of their sets play should say so.
    public struct EditOutcome {
        public let version: Tune
        public let name: String
        public let setsRepointed: Int
    }

    /// Replace a tune's notation with an edited version of it.
    ///
    /// The plain case, and the right one when what you were fixing was a
    /// mistake: there is no value in keeping the wrong notes beside the right
    /// ones.
    public static func saveEditInPlace(_ tune: Tune, abc: String,
                                       in context: ModelContext) {
        tune.abc = abc
        tune.updatedAt = Date()
        try? context.save()
    }

    /// Save edited notation as a new version, and make it the one sets play.
    ///
    /// The other right answer, and right for the other reason: a setting you
    /// play your own way is not a correction, and the version you were sent is
    /// worth keeping beside it.
    ///
    /// **Why this makes the edit the default when `saveTransposed` does not.**
    /// The two look alike and mean opposite things. Transposing is something
    /// you did to *read* the tune — you wanted it in another key for one
    /// session — so the original stays the one your sets play. Editing the
    /// notes is a statement that this is how the tune goes, and a version you
    /// believe in that your sets ignore is a version you will edit twice.
    ///
    /// Lives here rather than in either app because it is the rule that decides
    /// what a set plays, and a rule like that written down twice is a rule that
    /// will eventually be two rules.
    @discardableResult
    public static func saveEdited(_ source: Tune, abc: String, named name: String,
                                  in context: ModelContext) -> EditOutcome {
        let label = name.trimmingCharacters(in: .whitespaces)
        let title = label.isEmpty ? "\(TitleDisplay.plain(source.title)) (edited)" : label

        let edited = Tune(title: title, type: source.type,
                          key: source.key, mode: source.mode, abc: abc)
        edited.composer = source.composer
        edited.transcribedBy = source.transcribedBy
        edited.aliases = source.aliases
        // Carried, where the phone's own copy of this did not carry it. A note
        // saying where a setting came from or how it is played belongs to the
        // tune, not to one rendering of its notes, and `saveTransposed` two
        // functions up has always copied it.
        edited.notes = source.notes
        edited.sourceURL = source.sourceURL
        edited.theSessionID = source.theSessionID
        edited.rating = source.rating
        edited.isFavourite = source.isFavourite
        edited.onHitlist = source.onHitlist
        edited.versionLabel = title
        edited.transpose = 0

        // Join the source's group, or start one holding both, so the two sit
        // together as versions of one tune rather than as two unrelated tunes
        // with similar names.
        let groupID = source.groupID ?? UUID()
        source.groupID = groupID
        edited.groupID = groupID
        context.insert(edited)
        try? context.save()

        // Count what is about to move, before makeDefault repoints it.
        let group = versions(of: edited, in: context)
        let repointed = group
            .filter { $0 !== edited }
            .reduce(0) { $0 + ($1.setEntries ?? []).count }

        makeDefault(edited, in: context)

        return EditOutcome(version: edited, name: title, setsRepointed: repointed)
    }

    /// Root note of `tune.key` moved by `steps`, or "" if the key isn't a
    /// plain root we can shift (the library has its share of odd ones).
    public static func soundingKey(of tune: Tune, shiftedBy steps: Int) -> String {
        let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let root = String(tune.key.prefix(while: { $0.isLetter || $0 == "#" || $0 == "b" }))
        guard !root.isEmpty,
              let index = sharps.firstIndex(where: { $0.caseInsensitiveCompare(root) == .orderedSame })
        else { return "" }
        return sharps[((index + steps) % 12 + 12) % 12]
    }

    /// Every version in a tune's group, default first, then by label.
    public static func versions(of tune: Tune, in context: ModelContext) -> [Tune] {
        guard let groupID = tune.groupID else { return [tune] }
        let all = (try? context.fetch(
            FetchDescriptor<Tune>(predicate: #Predicate { $0.groupID == groupID })
        )) ?? [tune]
        return all.sorted {
            if $0.isDefaultVersion != $1.isDefaultVersion { return $0.isDefaultVersion }
            return $0.versionLabel < $1.versionLabel
        }
    }

    /// Make several settings into one tune.
    ///
    /// Lifted out of the Tunes list so the collection screen can offer the same
    /// action, and so there is one description of what grouping means rather
    /// than two that drift.
    ///
    /// Each setting keeps its own name as an alias, so searching for any of the
    /// spellings still finds the tune. The first in filing order becomes the
    /// default — the one the lists show and the one sets play — and that is a
    /// guess the Versions panel can overrule in a tap.
    @MainActor
    @discardableResult
    public static func group(_ tunes: [Tune], named name: String,
                             in context: ModelContext) -> Bool {
        let ordered = tunes.sorted { TitleDisplay.precedes($0.title, $1.title) }
        guard ordered.count > 1 else { return false }

        // Reuse an existing group id when one of the chosen settings already
        // belongs to a group, so this reads as "these are that tune too" rather
        // than making a third group alongside the two there already.
        let groupID = ordered.compactMap(\.groupID).first ?? UUID()
        let newName = name.trimmingCharacters(in: .whitespaces)

        // Which groups these settings are leaving, read before anything moves.
        let leaving = Set(ordered.compactMap(\.groupID))

        for (index, tune) in ordered.enumerated() {
            tune.groupID = groupID
            tune.isDefaultVersion = (index == 0)
            if !newName.isEmpty, tune.title != newName {
                if !tune.aliases.contains(tune.title) { tune.aliases.append(tune.title) }
                tune.title = newName
            }
            if tune.versionLabel.isEmpty && index > 0 {
                tune.versionLabel = tune.displayKey.isEmpty
                    ? "Setting \(index + 1)"
                    : "Setting \(index + 1) · \(tune.displayKey)"
            }
        }
        pointSetsAtDefault(of: ordered[0], in: ordered)
        try? context.save()

        // Taking a setting out of another group can leave *that* group with no
        // default, and a group with no default hides every one of its settings
        // — so grouping two tunes could silently make a third vanish. One of
        // the ways 75 of them went missing.
        VersionRepair.heal(groups: leaving.subtracting([groupID]), in: context)
        return true
    }

    /// The setting of this tune that the rest of the app shows.
    ///
    /// The Tunes list shows one row per tune: grouped settings collapse to
    /// whichever is the default. Anywhere else that lists tunes has to agree,
    /// or the same library is two different sizes depending on where you look
    /// at it — which is exactly what a collection did, listing "Bunny's Hat",
    /// "Bunny's Hat (edited)" and "Bunny's Hat in A" as three tunes.
    ///
    /// Not the same as filtering out non-defaults. A collection can hold a
    /// setting that is *not* the default — filed when it was, or filed on
    /// purpose — and dropping those rows would make tunes disappear from
    /// collections they are genuinely in. So this substitutes rather than
    /// removes: you get the default in its place, and the caller de-duplicates.
    ///
    /// Costs a fetch only for a tune that is both grouped and not the default,
    /// which is the rare case; everything else answers immediately.
    public static func shown(_ tune: Tune, in context: ModelContext) -> Tune {
        guard tune.groupID != nil, !tune.isDefaultVersion else { return tune }
        return versions(of: tune, in: context).first(where: \.isDefaultVersion) ?? tune
    }

    /// Whether a list of tunes "contains" one, in the same sense `shown`
    /// displays it.
    ///
    /// A collection can file a non-default setting, and `shown` then shows its
    /// default sibling in that row instead — so a check against the raw list
    /// using plain identity can miss a tune that is genuinely filed there, just
    /// under a different setting. This answers the question `shown`'s callers
    /// actually need: does `tunes` hold this tune, or another setting from the
    /// same version group?
    ///
    /// No fetch: two records are in the same group exactly when their
    /// `groupID`s match, which is already in hand on both sides.
    public static func collection(_ tunes: [Tune], contains tune: Tune) -> Bool {
        tunes.contains {
            $0 === tune || (tune.groupID != nil && $0.groupID == tune.groupID)
        }
    }

    /// How many tunes a list of records actually amounts to.
    ///
    /// The companion to `shown`. A badge reading 12 above a list of 10 rows is
    /// its own small bug, so anywhere that collapses version groups for display
    /// has to count them the same way.
    ///
    /// No fetch and no context: two records collapse into one exactly when they
    /// share a `groupID`, and that is already in hand.
    public static func shownCount(of tunes: [Tune]) -> Int {
        var groups: Set<UUID> = []
        var count = 0
        for tune in tunes {
            if let group = tune.groupID {
                if groups.insert(group).inserted { count += 1 }
            } else {
                count += 1
            }
        }
        return count
    }

    /// Everything attached anywhere in a tune's version group.
    ///
    /// A recording of you playing Calliope House is a recording of *the tune*,
    /// not of one setting of it — but attachments hang off a single `Tune`
    /// record, and an import matches on title *and notation*, so a file lands
    /// on whichever setting its notes happen to match. In this library that put
    /// Calliope House's recording on "Version in D major" while the row you
    /// open by default is a different record, and the tune looked as though it
    /// had nothing attached.
    ///
    /// Rather than move the data — which would be guessing at which version a
    /// recording is really of — the whole group is shown, and anything from a
    /// sibling is labelled with the version it belongs to.
    ///
    /// Returns `(item, owner)` pairs, the tune's own first.
    public static func mediaAcrossGroup(of tune: Tune,
                                        in context: ModelContext) -> [(item: MediaItem, owner: Tune)] {
        let group = versions(of: tune, in: context)
        var out: [(item: MediaItem, owner: Tune)] = []
        // The tune you are looking at first, so its own attachments stay where
        // you expect them.
        for item in (tune.media ?? []) { out.append((item, tune)) }
        for other in group where other !== tune {
            for item in (other.media ?? []) { out.append((item, other)) }
        }
        return out
    }

    /// Make `newDefault` the group's default and repoint every set entry that
    /// used any version of this tune, so sets always play the default.
    public static func makeDefault(_ newDefault: Tune, in context: ModelContext) {
        let group = versions(of: newDefault, in: context)
        for tune in group { tune.isDefaultVersion = (tune === newDefault) }
        pointSetsAtDefault(of: newDefault, in: group)
        try? context.save()
    }

    /// Repoint set entries from any version in `group` to `defaultTune`.
    public static func pointSetsAtDefault(of defaultTune: Tune, in group: [Tune]) {
        for tune in group where tune !== defaultTune {
            for entry in tune.setEntries ?? [] {
                entry.tune = defaultTune
            }
        }
    }

    /// Delete one version. If it was the default, another version takes over
    /// (and inherits its place in any sets). A group left with one tune is
    /// ungrouped so it behaves as an ordinary tune again.
    /// Returns the version to show next, if any.
    @discardableResult
    public static func delete(_ version: Tune, in context: ModelContext) -> Tune? {
        let group = versions(of: version, in: context)
        let remaining = group.filter { $0 !== version }

        guard !remaining.isEmpty else {
            context.delete(version)
            try? context.save()
            return nil
        }

        // Whoever takes over inherits this version's set appearances.
        let successor = remaining.first { !$0.abc.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? remaining[0]
        for entry in version.setEntries ?? [] { entry.tune = successor }

        if version.isDefaultVersion { successor.isDefaultVersion = true }
        context.delete(version)

        if remaining.count == 1, let last = remaining.first {
            last.groupID = nil
            last.versionLabel = ""
            last.isDefaultVersion = true
        }
        try? context.save()
        return remaining.contains(where: { $0 === successor }) ? successor : remaining.first
    }
}
