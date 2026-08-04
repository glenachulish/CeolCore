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
