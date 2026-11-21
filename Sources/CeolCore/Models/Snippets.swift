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

    /// What snippets.html's loadABC() is handed: the rows as JSON text. Tunes
    /// with no music yet are left out and counted.
    public static func payload(for tunes: [Tune]) -> String {
        let withMusic = tunes.filter(\.hasNotation)
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
        let payload = Payload(tunes: rows, withoutMusic: tunes.count - withMusic.count)
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
