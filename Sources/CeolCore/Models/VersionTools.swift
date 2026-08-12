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
