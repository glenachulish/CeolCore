import Foundation
import SwiftData

// FONN-SNIPPETS-1
/// The opening bars of every tune, as one compact list to jog the memory:
/// sorted by type and key, filtered by stars, hitlist, favourites and
/// collection. The list itself is Web/snippets.html (shared by the phone and
/// the Mac); this chooses the tunes and builds what the page is given.
public struct SnippetFilter: Equatable {
    public var minRating = 0
    public var hitlistOnly = false
    public var favouritesOnly = false
    /// A collection's uuid, or nil for the whole library.
    public var collectionID: UUID? = nil

    public init(minRating: Int = 0, hitlistOnly: Bool = false,
                favouritesOnly: Bool = false, collectionID: UUID? = nil) {
        self.minRating = minRating
        self.hitlistOnly = hitlistOnly
        self.favouritesOnly = favouritesOnly
        self.collectionID = collectionID
    }

    /// Kept per device under these keys, so the list opens as you left it.
    public static let ratingKey = "fonn.snippets.minRating"
    public static let hitlistKey = "fonn.snippets.hitlist"
    public static let favouritesKey = "fonn.snippets.favourites"
    public static let collectionKey = "fonn.snippets.collection"

    /// FONN-SNIPKEEP-1: names these filters, so the page knows whether a
    /// refreshed list is the same list (keep your place) or a new one (top).
    public var key: String {
        "\(minRating)|\(hitlistOnly)|\(favouritesOnly)|\(collectionID?.uuidString ?? "")"
    }

    /// Where you were in the list (the tune at the top of the screen), and
    /// for which filters, kept per device.
    public static let anchorKey = "fonn.snippets.anchor"
    public static let anchorListKey = "fonn.snippets.anchorList"

    public var isFiltered: Bool {
        minRating > 0 || hitlistOnly || favouritesOnly || collectionID != nil
    }
}

public enum Snippets {

    struct Row: Encodable {
        let id: String
        let title: String
        let sortTitle: String
        let type: String
        let key: String
        let abc: String
        let transpose: Int
        let rating: Int
        let favourite: Bool
        let hitlist: Bool
    }

    struct Payload: Encodable {
        let tunes: [Row]
        let withoutMusic: Int
        let list: String
    }

    /// One row per tune, as the library shows them (the default version of a
    /// group), through the filter. A tune counts as in a collection when any
    /// of its versions is filed there.
    public static func tunes(from all: [Tune], filter: SnippetFilter,
                             collections: [TuneCollection]) -> [Tune] {
        var inCollection: (uuids: Set<UUID>, groups: Set<UUID>)? = nil
        if let id = filter.collectionID,
           let collection = collections.first(where: { $0.uuid == id }) {
            let filed = collection.tunes ?? []
            inCollection = (Set(filed.map(\.uuid)), Set(filed.compactMap(\.groupID)))
        }
        return all.filter { tune in
            if tune.groupID != nil && !tune.isDefaultVersion { return false }
            if filter.minRating > 0 && tune.rating < filter.minRating { return false }
            if filter.hitlistOnly && !tune.onHitlist { return false }
            if filter.favouritesOnly && !tune.isFavourite { return false }
            if let inCollection {
                let byGroup = tune.groupID.map { inCollection.groups.contains($0) } ?? false
                if !inCollection.uuids.contains(tune.uuid) && !byGroup { return false }
            }
            return true
        }
    }

    /// FONN-SNIPKEEP-1: snippets.html says, as you scroll, which tune is at
    /// the top of the screen. Kept per device, so the list opens there.
    /// True when the message was one of these.
    ///
    /// FONN-SNIPKEEP-2: held in memory while you scroll and written to
    /// UserDefaults only when the list closes (`savePlace`). Writing it on
    /// every pause in scrolling made SwiftUI redraw the page, which handed
    /// the list over again and sent you back.
    @discardableResult
    public static func rememberPlace(from message: [String: Any]) -> Bool {
        guard let anchor = message["anchor"] as? String else { return false }
        place = (anchor, message["list"] as? String ?? "")
        return true
    }

    nonisolated(unsafe) private static var place: (anchor: String, list: String)?

    /// When the list closes, or a tune is opened from it.
    public static func savePlace() {
        guard let place else { return }
        UserDefaults.standard.set(place.anchor, forKey: SnippetFilter.anchorKey)
        UserDefaults.standard.set(place.list, forKey: SnippetFilter.anchorListKey)
    }

    /// Run when the page loads: back to the remembered tune, if it was
    /// remembered for these same filters.
    public static func returnScript(list: String) -> String? {
        let defaults = UserDefaults.standard
        let kept = place ?? (defaults.string(forKey: SnippetFilter.anchorKey) ?? "",
                             defaults.string(forKey: SnippetFilter.anchorListKey) ?? "")
        let anchor = kept.anchor
        guard UUID(uuidString: anchor) != nil, kept.list == list else { return nil }
        return "snippetsScrollTo(\"\(anchor)\");"
    }

    /// What snippets.html's loadABC() is handed: the rows as JSON text. Tunes
    /// with no music yet are left out and counted.
    public static func payload(for tunes: [Tune], list: String = "") -> String {
        // FONN-SNIPKEEP-2: in a fixed order (the page sorts them its own
        // way), so the same library always makes the same text and the page
        // is only handed a list when something in it really changed.
        let withMusic = tunes.filter(\.hasNotation).sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        let rows = withMusic.map { tune in
            Row(id: tune.uuid.uuidString,
                title: TitleDisplay.plain(tune.title),
                sortTitle: TitleDisplay.sortKey(tune.title),
                type: tune.type.lowercased(),
                key: tune.displayKey,
                abc: tune.abc,
                transpose: tune.transpose,
                rating: tune.rating,
                favourite: tune.isFavourite,
                hitlist: tune.onHitlist)
        }
        let payload = Payload(tunes: rows, withoutMusic: tunes.count - withMusic.count, list: list)
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
