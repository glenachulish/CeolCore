import Foundation
import SwiftData

// FONN-BOOK-1
/// A collection as a printed book: a cover, the contents, then one page per
/// tune with its page number. The layout is Web/book.html, shared by the phone
/// and the Mac; this builds what the page is given.
public enum CollectionBook {

    struct Payload: Encodable {
        let title: String
        let about: String
        let date: String
        let tunes: [Page]
    }

    struct Page: Encodable {
        let title: String
        let abc: String
        let type: String
        let key: String
        let transpose: Int
    }

    /// The tunes in book order: the collection's own, as its list shows them,
    /// then the tunes of the sets filed in it, set by set, each tune once.
    public static func tunes(shown: [Tune], in collection: TuneCollection) -> [Tune] {
        var seen = Set(shown.map(\.uuid))
        var out = shown
        let sets = (collection.sets ?? []).sorted { TitleDisplay.precedes($0.name, $1.name) }
        for set in sets {
            for entry in set.orderedEntries {
                guard let tune = entry.tune, !seen.contains(tune.uuid) else { continue }
                seen.insert(tune.uuid)
                out.append(tune)
            }
        }
        return out.filter { $0.hasNotation }
    }

    /// What book.html's loadABC() is handed: the book as JSON text.
    public static func payload(title: String, about: String, tunes: [Tune]) -> String {
        let pages = tunes.map {
            Page(title: TitleDisplay.plain($0.title), abc: $0.abc, type: $0.type,
                 key: $0.displayKey, transpose: $0.transpose)
        }
        let book = Payload(title: title, about: about,
                           date: Date.now.formatted(date: .long, time: .omitted),
                           tunes: pages)
        guard let data = try? JSONEncoder().encode(book),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
