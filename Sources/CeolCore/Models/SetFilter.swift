import Foundation

// FONN-SETFILTER-1
/// The library's filters, for sets.
///
/// A set has its own stars, hitlist and favourite, so those filter the set
/// itself. Type, key and attachments are about the tunes in it: a set
/// "is" a reel set if it has a reel in it, so "Reel" finds every set with a
/// reel, mixed sets included; a key finds every set that goes through it. An
/// attachment counts whether it is on the set or on one of its tunes, since
/// either way it's there when you open the set.
///
/// The library's "In a set?" becomes "In a collection?" here — the same
/// question asked one level up.
public struct SetListFilter: Equatable, Sendable, Codable {

    public enum Content: String, CaseIterable, Identifiable, Sendable, Codable {
        case any, allNotation, someNoNotation, anyMedia, audio, video, images, links

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .any:            return "Anything"
            case .allNotation:    return "All have sheet music"
            case .someNoNotation: return "Some without sheet music"
            case .anyMedia:       return "Has media"
            case .audio:          return "Has a recording"
            case .video:          return "Has video"
            case .images:         return "Has photos or PDFs"
            case .links:          return "Has a link"
            }
        }

        public func matches(_ set: TuneSet) -> Bool {
            let tunes = set.orderedEntries.compactMap(\.tune)
            switch self {
            case .any:            return true
            case .allNotation:    return !tunes.isEmpty && tunes.allSatisfy(\.hasNotation)
            case .someNoNotation: return tunes.contains { !$0.hasNotation }
            case .anyMedia:       return Self.has(nil, set, tunes)
            case .audio:          return Self.has([.audio], set, tunes)
            case .video:          return Self.has([.video], set, tunes)
            case .images:         return Self.has([.photo, .pdf], set, tunes)
            case .links:          return Self.has([.link], set, tunes)
            }
        }

        /// On the set itself, or on any of its tunes. Nil kinds means any.
        static func has(_ kinds: Set<MediaKind>?, _ set: TuneSet, _ tunes: [Tune]) -> Bool {
            let wanted: (MediaItem) -> Bool = { item in kinds.map { $0.contains(item.kind) } ?? true }
            if (set.media ?? []).contains(where: wanted) { return true }
            return tunes.contains { ($0.media ?? []).contains(where: wanted) }
        }
    }

    public enum InCollection: String, CaseIterable, Identifiable, Sendable, Codable {
        case any, inCollection, notInCollection

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .any:             return "In a collection?"
            case .inCollection:    return "In a collection"
            case .notInCollection: return "Not in any collection"
            }
        }

        public func matches(_ set: TuneSet) -> Bool {
            switch self {
            case .any:             return true
            case .inCollection:    return !(set.collections ?? []).isEmpty
            case .notInCollection: return (set.collections ?? []).isEmpty
            }
        }
    }

    /// Empty means any, as in `TuneFilter`.
    public var type = ""
    public var key = ""
    public var minRating = 0
    public var favourites = false
    public var hitlist = false
    public var content: Content = .any
    public var inCollection: InCollection = .any

    public init() {}

    public var isActive: Bool {
        !type.isEmpty || !key.isEmpty || minRating > 0
            || favourites || hitlist || content != .any || inCollection != .any
    }

    /// Cheap tests first.
    public func matches(_ set: TuneSet) -> Bool {
        if favourites && !set.isFavourite { return false }
        if hitlist && !set.onHitlist { return false }
        if minRating > 0 && set.rating < minRating { return false }
        if !inCollection.matches(set) { return false }
        if !type.isEmpty || !key.isEmpty {
            let tunes = set.orderedEntries.compactMap(\.tune)
            if !type.isEmpty,
               !tunes.contains(where: { $0.type.caseInsensitiveCompare(type) == .orderedSame }) {
                return false
            }
            if !key.isEmpty, !tunes.contains(where: { $0.displayKey == key }) { return false }
        }
        if !content.matches(set) { return false }
        return true
    }

    // MARK: - What is currently on

    public var active: [TuneFilter.Active] {
        var out: [TuneFilter.Active] = []
        if favourites { out.append(.init(id: "favourites", label: "Favourites")) }
        if hitlist { out.append(.init(id: "hitlist", label: "Hitlist")) }
        if !type.isEmpty {
            let t = type.lowercased()
            let article = "aeiou".contains(t.first ?? "x") ? "an" : "a"
            out.append(.init(id: "type", label: "Has \(article) \(t)"))
        }
        if !key.isEmpty { out.append(.init(id: "key", label: "In \(key)")) }
        if minRating > 0 {
            out.append(.init(id: "rating", label: String(repeating: "★", count: minRating) + " and up"))
        }
        if content != .any { out.append(.init(id: "content", label: content.label)) }
        if inCollection != .any { out.append(.init(id: "inCollection", label: inCollection.label)) }
        return out
    }

    public mutating func clear(_ id: String) {
        switch id {
        case "favourites":   favourites = false
        case "hitlist":      hitlist = false
        case "type":         type = ""
        case "key":          key = ""
        case "rating":       minRating = 0
        case "content":      content = .any
        case "inCollection": inCollection = .any
        default:             break
        }
    }

    public mutating func clearAll() { self = SetListFilter() }

    // MARK: - The vocabulary the sets actually use

    /// The types of the tunes in these sets, as `TuneFilter.types` lists them.
    public static func types(in sets: [TuneSet]) -> [String] {
        TuneFilter.types(in: sets.flatMap { $0.orderedEntries.compactMap(\.tune) })
    }

    public static func keys(in sets: [TuneSet]) -> [String] {
        TuneFilter.keys(in: sets.flatMap { $0.orderedEntries.compactMap(\.tune) })
    }
}
