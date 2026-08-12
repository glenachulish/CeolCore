import Foundation

/// What you are looking for in a library of a thousand tunes.
///
/// The rules live here rather than in either app's list view, because they are
/// facts about a tune and not about a screen. The phone puts them behind a
/// sheet and shows what is set as chips; the Mac has room for them in a row.
/// Both should agree about what "has media" means.
public struct TuneFilter: Equatable, Sendable {

    /// What the tune has attached, or doesn't.
    public enum Content: String, CaseIterable, Identifiable, Sendable {
        case any, notation, noNotation, anyMedia, audio, video, images, links, videoLinks, audioLinks

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .any:        return "Anything"
            // "Sheet music" rather than "notation" — that is what it is called
            // when you are looking for it.
            case .notation:   return "Has sheet music"
            case .noNotation: return "No sheet music"
            case .anyMedia:   return "Has media"
            case .audio:      return "Has recordings"
            case .video:      return "Has video"
            case .images:     return "Has photos or PDFs"
            // Links are worth their own answer. 55 tunes carry a web address —
            // a YouTube recording of the tune, a page it came from — and until
            // now the only way to find them was to remember which.
            case .links:      return "Has a link"
            case .videoLinks: return "Has a video link"
            // A recording you stream, as against the 307 kept on disk.
            case .audioLinks: return "Has an audio link"
            }
        }

        public func matches(_ tune: Tune) -> Bool {
            switch self {
            case .any:        return true
            case .notation:   return tune.hasNotation
            case .noNotation: return !tune.hasNotation
            case .anyMedia:   return !(tune.media ?? []).isEmpty
            case .audio:      return tune.hasMedia([.audio])
            case .video:      return tune.hasMedia([.video])
            case .images:     return tune.hasMedia([.photo, .pdf])
            case .links:      return tune.hasMedia([.link])
            // A link that is a video to watch, rather than a page to read.
            case .videoLinks: return (tune.media ?? []).contains {
                                  $0.kind == .link && $0.youTubeID != nil
                              }
            case .audioLinks: return (tune.media ?? []).contains(\.isAudioLink)
            }
        }
    }

    public enum InSet: String, CaseIterable, Identifiable, Sendable {
        case any, inSet, notInSet

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .any:      return "In a set?"
            case .inSet:    return "In a set"
            case .notInSet: return "Not in any set"
            }
        }

        public func matches(_ tune: Tune) -> Bool {
            switch self {
            case .any:      return true
            case .inSet:    return tune.isInASet
            case .notInSet: return !tune.isInASet
            }
        }
    }

    /// Empty string means "any" for the two text filters — not a magic "All"
    /// string, which has to be spelled identically in three places to work.
    public var type = ""
    public var key = ""
    public var minRating = 0
    public var favourites = false
    public var hitlist = false
    public var content: Content = .any
    public var inSet: InSet = .any

    public init() {}

    public var isActive: Bool {
        !type.isEmpty || !key.isEmpty || minRating > 0
            || favourites || hitlist || content != .any || inSet != .any
    }

    /// Cheap tests first: this runs across the whole library on every keystroke.
    public func matches(_ tune: Tune) -> Bool {
        if favourites && !tune.isFavourite { return false }
        if hitlist && !tune.onHitlist { return false }
        if minRating > 0 && tune.rating < minRating { return false }
        if !type.isEmpty && tune.type.caseInsensitiveCompare(type) != .orderedSame { return false }
        if !key.isEmpty && tune.displayKey != key { return false }
        if !content.matches(tune) { return false }
        if !inSet.matches(tune) { return false }
        return true
    }

    // MARK: - What is currently on

    /// One filter that is set, so a list can show it and offer to switch it off.
    public struct Active: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
    }

    public var active: [Active] {
        var out: [Active] = []
        if favourites { out.append(Active(id: "favourites", label: "Favourites")) }
        if hitlist { out.append(Active(id: "hitlist", label: "Hitlist")) }
        if !type.isEmpty { out.append(Active(id: "type", label: type.capitalized)) }
        if !key.isEmpty { out.append(Active(id: "key", label: key)) }
        if minRating > 0 {
            out.append(Active(id: "rating",
                              label: String(repeating: "★", count: minRating) + " and up"))
        }
        if content != .any { out.append(Active(id: "content", label: content.label)) }
        if inSet != .any { out.append(Active(id: "inSet", label: inSet.label)) }
        return out
    }

    public mutating func clear(_ id: String) {
        switch id {
        case "favourites": favourites = false
        case "hitlist":    hitlist = false
        case "type":       type = ""
        case "key":        key = ""
        case "rating":     minRating = 0
        case "content":    content = .any
        case "inSet":      inSet = .any
        default:           break
        }
    }

    public mutating func clearAll() { self = TuneFilter() }

    // MARK: - The vocabulary a library actually uses

    /// The tune types present, so the menu offers reel and strathspey rather
    /// than a fixed list that does not match what you have.
    public static func types(in tunes: [Tune]) -> [String] {
        var seen = Set<String>()
        for tune in tunes {
            let t = tune.type.trimmingCharacters(in: .whitespaces).lowercased()
            if !t.isEmpty { seen.insert(t) }
        }
        return seen.sorted()
    }

    public static func keys(in tunes: [Tune]) -> [String] {
        var seen = Set<String>()
        for tune in tunes {
            let k = tune.displayKey
            if !k.isEmpty { seen.insert(k) }
        }
        return seen.sorted()
    }
}
