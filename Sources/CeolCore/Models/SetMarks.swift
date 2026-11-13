import Foundation
import SwiftData

// FONN-MARKS-4
/// A set's marked music kept as a set of its own.
///
/// Sets have no versions as tunes do, so the marked one is a second set: the
/// same tunes in the same order with the same repeats, named after the first
/// with "(marked)", carrying everything highlighted, written and drawn on it.
/// The set it came from keeps its name, its place in your collections and its
/// stars, and goes back to clean music.
public enum SetMarks {

    /// True when anything is marked on any tune in the set.
    public static func hasMarks(_ set: TuneSet) -> Bool {
        (set.entries ?? []).contains { !$0.marks.isEmpty }
    }

    /// Move the set's marks onto a copy of it, and leave the set clean. Nil
    /// when nothing is marked.
    @discardableResult
    public static func saveMarkedCopy(of source: TuneSet, in context: ModelContext) -> TuneSet? {
        guard hasMarks(source) else { return nil }

        let taken = Set(((try? context.fetch(FetchDescriptor<TuneSet>())) ?? []).map(\.name))
        var name = "\(source.name) (marked)"
        var number = 2
        while taken.contains(name) {
            name = "\(source.name) (marked \(number))"
            number += 1
        }

        let copy = TuneSet(name: name)
        copy.notes = source.notes
        copy.droneSound = source.droneSound
        copy.droneNote = source.droneNote
        context.insert(copy)
        // In the same collections, so it is found beside the set it came from.
        copy.collections = source.collections

        for original in source.orderedEntries {
            let entry = SetEntry(position: original.position, repeats: original.repeats,
                                 tune: original.tune)
            entry.keyOverride = original.keyOverride
            entry.marks = original.marks
            entry.tuneSet = copy
            context.insert(entry)
            original.marks = ""
        }
        try? context.save()
        return copy
    }
}
