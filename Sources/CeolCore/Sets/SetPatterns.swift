import Foundation
import SwiftData

// FONN-SETPATTERN-1
/// Building a set round the circle of fifths, one tune at a time: a pattern of
/// moves, an opening tune, then at each step only the tunes that make the
/// pattern's next move. The rules are here; the screen (SetPatternBuilderView)
/// is shared by the phone and the Mac, so both build sets the same way.
///
/// A pattern is moves round the circle, not fixed keys. The old templates
/// named keys ("G major → D major → E dorian"), which only worked if your
/// opening tune happened to be in G. As moves (up a fifth, then the same key
/// family), the same shape works from whatever tune you start with — and from
/// G it is still G, D, E dorian.
public struct SetPattern: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    /// Steps round the circle from each tune to the next (+1 is up a fifth,
    /// sharpwards). Nil: free — you choose the move at each step.
    public let moves: [Int]?

    /// How many tunes the pattern makes, or nil for free.
    public var tuneCount: Int? { moves.map { $0.count + 1 } }

    public static let all: [SetPattern] = [
        SetPattern(id: "family", name: "Same key family",
                   detail: "Three tunes that share a key signature: D major, B minor, E dorian and A mixolydian, say. The smoothest set there is.",
                   moves: [0, 0]),
        SetPattern(id: "triangle", name: "The triangle",
                   detail: "Up a fifth, then a tune in the same family as that one. From G: G, D, E dorian. The most common Irish set shape.",
                   moves: [1, 0]),
        SetPattern(id: "modal", name: "Modal journey",
                   detail: "A tune in the same family, then up a fifth. From A dorian: A dorian, G, D. The sharps come in as the set goes on.",
                   moves: [0, 1]),
        SetPattern(id: "climb", name: "Climbing",
                   detail: "Up a fifth each time: G, D, A. The set brightens and lifts with every change.",
                   moves: [1, 1]),
        SetPattern(id: "lift", name: "Lift at the end",
                   detail: "Four tunes: three in the same key family, then up a fifth for the last one. The classic way to finish a set strongly.",
                   moves: [0, 0, 1]),
        SetPattern(id: "home", name: "There and back",
                   detail: "Up a fifth, then back down to where you started: D, A, D. Away and home.",
                   moves: [1, -1]),
        SetPattern(id: "settle", name: "Settling",
                   detail: "Down a fifth each time: A, D, G. The set mellows as it goes.",
                   moves: [-1, -1]),
        SetPattern(id: "pair", name: "A pair, up a fifth",
                   detail: "Two tunes, the second up a fifth: D into A.",
                   moves: [1]),
        SetPattern(id: "free", name: "Free",
                   detail: "Choose the move at every step (same family, up or down a fifth, two steps, or any key), and stop whenever you like.",
                   moves: nil),
    ]
}

/// A move from one tune to the next, for the free pattern and for labels.
public enum SetMove: Int, CaseIterable, Identifiable, Sendable {
    case same = 0, upFifth = 1, downFifth = -1, upTwo = 2, downTwo = -2, anyKey = 99

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .same: return "Same key family"
        case .upFifth: return "Up a fifth"
        case .downFifth: return "Down a fifth"
        case .upTwo: return "Two steps up"
        case .downTwo: return "Two steps down"
        case .anyKey: return "Any key"
        }
    }

    public static func describe(_ delta: Int) -> String {
        (SetMove(rawValue: delta) ?? .anyKey).label
    }
}

/// The filters: tune type, stars, hitlist, favourites, collection.
public struct SetBuilderFilter: Equatable {
    public var type = ""
    public var minRating = 0
    public var hitlistOnly = false
    public var favouritesOnly = false
    public var collectionID: UUID? = nil
    public init() {}

    public var isFiltered: Bool {
        !type.isEmpty || minRating > 0 || hitlistOnly || favouritesOnly || collectionID != nil
    }
}

public enum SetPatternLogic {

    /// The key signature a tune sits at (sharps positive, flats negative), or
    /// nil for a key that isn't on the circle.
    public static func signature(of tune: Tune) -> Int? {
        CircleOfFifths.signature(of: CircleOfFifths.keyName(of: tune))
    }

    /// The tunes the filters allow, one per tune (the default version of a
    /// group), leaving out the ones already in the set — and their other
    /// versions. A tune counts as in a collection if any version is filed there.
    public static func pool(_ all: [Tune], filter: SetBuilderFilter,
                            collections: [TuneCollection], excluding picked: [Tune]) -> [Tune] {
        let pickedIDs = Set(picked.map(\.uuid))
        let pickedGroups = Set(picked.compactMap(\.groupID))
        var members: (uuids: Set<UUID>, groups: Set<UUID>)? = nil
        if let id = filter.collectionID, let c = collections.first(where: { $0.uuid == id }) {
            let filed = c.tunes ?? []
            members = (Set(filed.map(\.uuid)), Set(filed.compactMap(\.groupID)))
        }
        let type = filter.type.lowercased()
        return all.filter { tune in
            if tune.groupID != nil && !tune.isDefaultVersion { return false }
            if pickedIDs.contains(tune.uuid) { return false }
            if let g = tune.groupID, pickedGroups.contains(g) { return false }
            if !type.isEmpty && tune.type.lowercased() != type { return false }
            if filter.minRating > 0 && tune.rating < filter.minRating { return false }
            if filter.hitlistOnly && !tune.onHitlist { return false }
            if filter.favouritesOnly && !tune.isFavourite { return false }
            if let members {
                let byGroup = tune.groupID.map { members.groups.contains($0) } ?? false
                if !members.uuids.contains(tune.uuid) && !byGroup { return false }
            }
            return true
        }
    }

    /// The signature the next tune needs, or nil for "any key".
    public static func target(after previous: Tune, move: Int) -> Int? {
        guard move != SetMove.anyKey.rawValue, let sig = signature(of: previous) else { return nil }
        return sig + move
    }

    /// The tunes that make the move, best first: the same type as the tune
    /// before, then favourites, then stars, then title.
    public static func candidates(after previous: Tune, move: Int, in pool: [Tune]) -> [Tune] {
        let wanted = target(after: previous, move: move)
        if move != SetMove.anyKey.rawValue && wanted == nil { return [] }
        let type = previous.type.lowercased()
        return pool
            .filter { wanted == nil || signature(of: $0) == wanted }
            .sorted { a, b in
                let ta = a.type.lowercased() == type, tb = b.type.lowercased() == type
                if ta != tb { return ta }
                if a.isFavourite != b.isFavourite { return a.isFavourite }
                if a.rating != b.rating { return a.rating > b.rating }
                return TitleDisplay.precedes(a.title, b.title)
            }
    }

    /// Opening tunes, best first: favourites, stars, title.
    public static func openers(in pool: [Tune]) -> [Tune] {
        pool.sorted { a, b in
            if a.isFavourite != b.isFavourite { return a.isFavourite }
            if a.rating != b.rating { return a.rating > b.rating }
            return TitleDisplay.precedes(a.title, b.title)
        }
    }

    /// The key families at a signature, for "what's wanted next" — "A major,
    /// F# minor, B dorian, E mixolydian".
    public static func keysLabel(atSignature sig: Int) -> String {
        let order = ["major", "minor", "dorian", "mixolydian"]
        return CircleOfFifths.keys(withSignature: sig)
            .filter { name in order.contains { name.hasSuffix(" " + $0) } && !name.hasSuffix(" aeolian") }
            .sorted { a, b in
                let ia = order.firstIndex { a.hasSuffix(" " + $0) } ?? 9
                let ib = order.firstIndex { b.hasSuffix(" " + $0) } ?? 9
                return ia < ib
            }
            .joined(separator: ", ")
    }

    /// The name a set gets when you don't give it one: the tunes in order,
    /// separated by " / ".
    public static func defaultName(_ tunes: [Tune]) -> String {
        tunes.map { TitleDisplay.plain($0.title) }.joined(separator: " / ")
    }

    /// Save the set and return it.
    @MainActor
    @discardableResult
    public static func save(_ tunes: [Tune], named name: String, in context: ModelContext) -> TuneSet {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let set = TuneSet(name: trimmed.isEmpty ? defaultName(tunes) : trimmed)
        context.insert(set)
        for (i, tune) in tunes.enumerated() {
            let entry = SetEntry(position: i, tune: tune)
            entry.tuneSet = set
            context.insert(entry)
        }
        try? context.save()
        return set
    }
}
