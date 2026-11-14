import Foundation
import SwiftData

// FONN-MARKUP-1
/// A marked-up PDF or photograph kept as an attachment of its own.
///
/// Sheet music drawn from ABC is marked with Fonn's own tools, which count
/// notes. A PDF or a photograph of a page has no notes to count, so those are
/// marked with the system's Markup (the phone and iPad) or in Preview (the
/// Mac), and what comes back is a file. It is kept beside the one it came
/// from, named after it with "(marked)", so the original stays clean — the
/// same rule as a marked tune or a marked set.
public enum MarkedCopy {

    /// Whether an attachment is the kind that can be marked: a PDF or a
    /// photograph with its file on this device.
    public static func canMark(_ item: MediaItem) -> Bool {
        (item.kind == .pdf || item.kind == .photo) && item.fileURL != nil
    }

    /// Store `file` as a new attachment beside `item`: same tune or set, same
    /// kind, last in the order. Nil if the file couldn't be copied in.
    @discardableResult
    public static func add(of item: MediaItem, from file: URL,
                           in context: ModelContext) -> MediaItem? {
        guard let stored = MediaStore.shared.copyIn(from: file) else { return nil }

        let siblings: [MediaItem] = item.tune?.media ?? item.tuneSet?.media ?? []
        let taken = Set(siblings.map(\.title))
        let base = item.displayTitle
        var title = "\(base) (marked)"
        var number = 2
        while taken.contains(title) {
            title = "\(base) (marked \(number))"
            number += 1
        }

        let copy = MediaItem(kind: item.kind, title: title, filename: stored)
        copy.position = (siblings.map(\.position).max() ?? item.position) + 1
        copy.tune = item.tune
        copy.tuneSet = item.tuneSet
        context.insert(copy)
        try? context.save()
        return copy
    }
}
