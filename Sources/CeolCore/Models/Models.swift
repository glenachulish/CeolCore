import Foundation
import SwiftData

// CloudKit-compatible SwiftData models.
// CloudKit rules: no unique constraints, every attribute optional or defaulted,
// every relationship optional with an inverse.
//
// Everything here is `public` because it now lives in a module of its own and
// both apps read and write it. The memberwise initialisers a @Model generates
// are internal, so each type also declares its own public init.

@Model
public final class Tune {
    public var uuid: UUID = UUID()
    public var title: String = ""
    public var type: String = ""          // reel, jig, hornpipe, ...
    public var key: String = ""           // e.g. D, G, Amaj
    public var mode: String = ""          // major, dorian, ...
    public var abc: String = ""
    public var notes: String = ""
    public var composer: String = ""
    public var transcribedBy: String = ""
    public var rating: Int = 0            // 0–5
    public var onHitlist: Bool = false
    public var isFavourite: Bool = false
    public var transpose: Int = 0
    /// The speed you practise this tune at, in quarter-note beats per minute.
    ///
    /// Deliberately not the same thing as the tune's own tempo. That one is
    /// `Q:` in the notation: it belongs to the music, drives playback, and
    /// travels with an export to anyone else. This is yours — the rate you
    /// tapped out because it is what you can currently play the tune at — and
    /// writing it into the notation would slow the tune down for good and for
    /// everybody.
    ///
    /// Sits alongside `rating`, `onHitlist` and `transpose`, which are the
    /// same sort of thing: how you are getting on with a tune rather than what
    /// the tune is. Optional with a default, so an existing library migrates
    /// unasked and CloudKit can carry it.
    public var practiceBPM: Int? = nil
    public var sourceURL: String = ""
    public var theSessionID: Int? = nil       // thesession.org tune id
    public var theSessionSettingID: String = ""
    public var versionLabel: String = ""      // e.g. "Setting 2 · Ador" when importing multiple settings
    /// Tunes sharing a groupID are versions/settings of the same tune.
    public var groupID: UUID? = nil
    /// The version shown in the library and used in sets. Exactly one per group.
    public var isDefaultVersion: Bool = true
    public var aliases: [String] = []
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    @Relationship(inverse: \TuneCollection.tunes)
    public var collections: [TuneCollection]? = []

    @Relationship(deleteRule: .cascade, inverse: \SetEntry.tune)
    public var setEntries: [SetEntry]? = []

    /// Recordings, videos, sheet-music photos, PDFs and links.
    @Relationship(deleteRule: .cascade)
    public var media: [MediaItem]? = []

    public init(title: String = "", type: String = "", key: String = "", mode: String = "", abc: String = "") {
        self.title = title
        self.type = type
        self.key = key
        self.mode = mode
        self.abc = abc
    }

    /// Whether there's real notation here, as opposed to nothing or the
    /// placeholder the Pi writes for a tune it knows only by name. A third of
    /// the library is name-only, so this is worth being able to filter on.
    public var hasNotation: Bool {
        let trimmed = abc.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("No ABC notation stored")
    }

    public func hasMedia(_ kinds: Set<MediaKind>) -> Bool {
        (media ?? []).contains { kinds.contains($0.kind) }
    }

    public var isInASet: Bool { !(setEntries ?? []).isEmpty }

    /// Display key like "Ddor" or "G"
    public var displayKey: String {
        let m = mode.lowercased()
        if m.isEmpty || m == "major" || m == "maj" { return key }
        return key + String(m.prefix(3))
    }
}

@Model
public final class TuneSet {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var notes: String = ""
    public var rating: Int = 0
    public var onHitlist: Bool = false
    public var isFavourite: Bool = false
    public var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \SetEntry.tuneSet)
    public var entries: [SetEntry]? = []

    /// Recordings, videos, photos, PDFs and links attached to the set.
    @Relationship(deleteRule: .cascade)
    public var media: [MediaItem]? = []

    /// A collection can hold sets as well as tunes.
    ///
    /// Optional with a default, like everything else here, so SwiftData
    /// migrates an existing library without being asked and CloudKit can carry
    /// it when stage 2 arrives. Keep it that way: CloudKit refuses
    /// non-optional properties without defaults, and refuses unique
    /// constraints.
    @Relationship(inverse: \TuneCollection.sets)
    public var collections: [TuneCollection]? = []

    public init(name: String = "") {
        self.name = name
    }

    public var orderedEntries: [SetEntry] {
        (entries ?? []).sorted { $0.position < $1.position }
    }
}

/// A tune's slot within a set (ordered, with per-set overrides).
@Model
public final class SetEntry {
    public var position: Int = 0
    /// How many times through. One by default — a set written out is a
    /// list of tunes, not a list of tunes twice, and the ⟳ buttons on the
    /// set page are there for the ones you do want doubled.
    public var repeats: Int = 1
    public var keyOverride: String = ""
    public var tune: Tune? = nil
    public var tuneSet: TuneSet? = nil

    public init(position: Int = 0, repeats: Int = 1, tune: Tune? = nil) {
        self.position = position
        self.repeats = repeats
        self.tune = tune
    }
}

/// What a piece of attached media is. Mirrors the kinds the Pi handles
/// (audio, video, photo, PDF, web link such as YouTube).
public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case audio, video, photo, pdf, link

    public var label: String {
        switch self {
        case .audio: return "Audio"
        case .video: return "Video"
        case .photo: return "Photo"
        case .pdf: return "PDF"
        case .link: return "Link"
        }
    }

    /// SF Symbol name. Wrong names fail at runtime and not at build, drawing
    /// nothing and saying so only in the console — so these are not to be
    /// edited casually. All five exist on both iOS 17 and macOS 14.
    public var icon: String {
        switch self {
        case .audio: return "waveform"
        case .video: return "video"
        case .photo: return "photo"
        case .pdf: return "doc.richtext"
        case .link: return "link"
        }
    }
}

/// A recording, video, photo of sheet music, PDF or link attached to a tune
/// or a set. Files live in the app's Documents/Media folder; only the
/// filename is stored here (so the record stays small and CloudKit-friendly).
@Model
public final class MediaItem {
    public var uuid: UUID = UUID()
    public var kindRaw: String = MediaKind.audio.rawValue
    /// Stored file name inside Documents/Media (empty for links).
    public var filename: String = ""
    /// Web address, for `.link` items (YouTube and the like).
    public var urlString: String = ""
    public var title: String = ""
    public var notes: String = ""
    public var createdAt: Date = Date()

    @Relationship(inverse: \Tune.media) public var tune: Tune?
    @Relationship(inverse: \TuneSet.media) public var tuneSet: TuneSet?

    public var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .audio }
        set { kindRaw = newValue.rawValue }
    }

    public init(kind: MediaKind, title: String = "", filename: String = "", urlString: String = "") {
        self.kindRaw = kind.rawValue
        self.title = title
        self.filename = filename
        self.urlString = urlString
    }

    /// Where the file actually is on this device.
    public var fileURL: URL? {
        guard !filename.isEmpty else { return nil }
        return MediaStore.shared.url(for: filename)
    }

    /// App Transport Security refuses plain `http`, so a link saved as http —
    /// and thirteen came across from the Pi that way — can only ever fail to
    /// load. Every public site these links point at serves https, so promote
    /// the scheme rather than let the request be refused. Local addresses are
    /// the exception: ATS allows them as they are, and they don't do https.
    public var webURL: URL? {
        guard !urlString.isEmpty, var parts = URLComponents(string: urlString) else { return nil }
        if parts.scheme?.lowercased() == "http" {
            let host = parts.host?.lowercased() ?? ""
            let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
            if !isLocal { parts.scheme = "https" }
        }
        return parts.url
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if kind == .link { return urlString }
        return filename
    }
}

@Model
public final class TuneCollection {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var about: String = ""
    public var isFavourite: Bool = false
    public var onHitlist: Bool = false
    public var createdAt: Date = Date()

    public var tunes: [Tune]? = []

    /// Sets filed into this collection. The inverse lives on `TuneSet`.
    public var sets: [TuneSet]? = []

    public init(name: String = "", about: String = "") {
        self.name = name
        self.about = about
    }
}
