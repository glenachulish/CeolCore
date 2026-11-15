import Foundation
import SwiftData

// FONN-RESOURCES-1
// Resources (folder Links/, not Resources/: see Package.swift on that name): links to things online (articles, videos, recordings, archive
// entries), kept in folders you make, and shareable with someone else who has
// Fonn. Plan: FONN_RESOURCES_LINKS_PLAN_15NOV2026.md in the Ceòl Traidiseanta
// project.
//
// CloudKit rules, as in Models.swift: every attribute defaulted, every
// relationship optional with an inverse, no unique constraints. **Two new
// record types (CD_LinkFolder, CD_SavedLink) and their relationships need
// Deploy Schema Changes to Production before a TestFlight build ships them.**

/// A folder in Resources. A link can be in several, like a tune in several
/// collections; deleting a folder leaves its links in Resources.
@Model
public final class LinkFolder {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var about: String = ""
    public var createdAt: Date = Date()

    @Relationship(inverse: \SavedLink.folders)
    public var links: [SavedLink]? = []

    public init(name: String = "", about: String = "") {
        self.name = name
        self.about = about
    }

    /// Newest first: what you have just saved is what you are looking for.
    public var sortedLinks: [SavedLink] {
        (links ?? []).sorted { $0.createdAt > $1.createdAt }
    }
}

/// One link in Resources.
@Model
public final class SavedLink {
    public var uuid: UUID = UUID()
    public var urlString: String = ""
    public var title: String = ""
    public var notes: String = ""
    public var kindRaw: String = LinkKind.article.rawValue
    public var createdAt: Date = Date()

    public var folders: [LinkFolder]? = []
    /// The inverse lives on `Tune.savedLinks`.
    public var tunes: [Tune]? = []
    /// The inverse lives on `TuneSet.savedLinks`.
    public var sets: [TuneSet]? = []

    public init(urlString: String = "", title: String = "", kind: LinkKind = .article) {
        self.urlString = urlString
        self.title = title
        self.kindRaw = kind.rawValue
    }

    public var kind: LinkKind {
        get { LinkKind(rawValue: kindRaw) ?? .article }
        set { kindRaw = newValue.rawValue }
    }

    /// As `MediaItem.webURL`: plain http is promoted to https, which every
    /// public site serves and App Transport Security insists on.
    public var webURL: URL? {
        guard !urlString.isEmpty, var parts = URLComponents(string: urlString) else { return nil }
        if parts.scheme?.lowercased() == "http" {
            let host = parts.host?.lowercased() ?? ""
            let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
            if !isLocal { parts.scheme = "https" }
        }
        return parts.url
    }

    /// The site, without "www." — "youtube.com", "tobarandualchais.co.uk".
    public var host: String {
        let raw = URL(string: urlString)?.host ?? ""
        return raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host.isEmpty ? urlString : host
    }

    public var sortedFolders: [LinkFolder] {
        (folders ?? []).sorted { TitleDisplay.precedes($0.name, $1.name) }
    }

    public var sortedTunes: [Tune] {
        (tunes ?? []).sorted { TitleDisplay.precedes($0.title, $1.title) }
    }
}

/// What a link is, for its icon and for filtering. Guessed from the address
/// when it is saved; you can change it.
public enum LinkKind: String, CaseIterable, Identifiable, Sendable {
    case video
    case recording
    case archive
    case article

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .video: return "Video"
        case .recording: return "Recording"
        case .archive: return "Archive"
        case .article: return "Article or page"
        }
    }

    public var systemImage: String {
        switch self {
        case .video: return "play.rectangle"
        case .recording: return "waveform"
        case .archive: return "building.columns"
        case .article: return "doc.text"
        }
    }

    /// A guess from the address alone. Good enough to start with: the kind
    /// is only an icon and a filter, and you can correct it.
    public static func guess(for url: URL) -> LinkKind {
        let host = (url.host ?? "").lowercased()
        let ext = url.pathExtension.lowercased()
        func on(_ site: String) -> Bool { host == site || host.hasSuffix("." + site) }

        if ["youtube.com", "youtu.be", "vimeo.com", "tiktok.com"].contains(where: on)
            || ["mp4", "mov", "m4v", "webm"].contains(ext) {
            return .video
        }
        if ["tobarandualchais.co.uk", "raretunes.org", "itma.ie", "archive.org",
            "ambaile.org.uk", "calum-maclean-project.ed.ac.uk"].contains(where: on) {
            return .archive
        }
        if ["soundcloud.com", "bandcamp.com", "spotify.com", "music.apple.com",
            "mixcloud.com"].contains(where: on)
            || ["mp3", "m4a", "wav", "aif", "aiff", "ogg", "flac"].contains(ext) {
            return .recording
        }
        return .article
    }
}

/// Saving and finding links. In CeolCore so the share inbox, the drop target,
/// the editor and a shared file all do it the same way.
public enum ResourceLinks {

    /// An address as typed or pasted, made into a web URL — or nil if it
    /// isn't one. "youtube.com/watch?v=…" gets its https://; text with no
    /// dotted host, or a scheme other than http(s), is refused.
    public static func url(from text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(" ") else { return nil }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            guard !raw.contains("://") else { return nil }
            raw = "https://" + raw
        }
        guard let url = URL(string: raw),
              let host = url.host, host.contains("."),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Two addresses count as the same link when they differ only in http/s,
    /// "www.", a trailing slash or letter case in the host.
    public static func sameKey(_ text: String) -> String {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return text.lowercased() }
        parts.scheme = "https"
        if var host = parts.host?.lowercased() {
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            parts.host = host
        }
        if parts.path.hasSuffix("/") { parts.path = String(parts.path.dropLast()) }
        return parts.string ?? text.lowercased()
    }

    /// The link already in Resources at this address, if there is one.
    public static func existing(_ urlString: String, in context: ModelContext) -> SavedLink? {
        let key = sameKey(urlString)
        let all = (try? context.fetch(FetchDescriptor<SavedLink>())) ?? []
        return all.first { sameKey($0.urlString) == key }
    }

    /// Save a link, or file the one already there into `folder` / against
    /// `tune`. Never makes a second copy of an address.
    @discardableResult
    public static func save(_ url: URL, title: String = "", folder: LinkFolder? = nil,
                            tune: Tune? = nil, in context: ModelContext) -> (link: SavedLink, isNew: Bool) {
        if let link = existing(url.absoluteString, in: context) {
            if link.title.isEmpty, !title.isEmpty { link.title = title }
            file(link, folder: folder, tune: tune)
            return (link, false)
        }
        let link = SavedLink(urlString: url.absoluteString, title: title, kind: LinkKind.guess(for: url))
        context.insert(link)
        file(link, folder: folder, tune: tune)
        return (link, true)
    }

    private static func file(_ link: SavedLink, folder: LinkFolder?, tune: Tune?) {
        if let folder, !(link.folders ?? []).contains(where: { $0 === folder }) {
            link.folders = (link.folders ?? []) + [folder]
        }
        if let tune, !(link.tunes ?? []).contains(where: { $0 === tune }) {
            link.tunes = (link.tunes ?? []) + [tune]
        }
    }

    /// Fill in a title from the page, for a link saved without a real one.
    /// Quietly does nothing offline or for a page that won't say.
    @MainActor
    public static func fillTitle(_ link: SavedLink, in context: ModelContext) async {
        let current = link.title.trimmingCharacters(in: .whitespaces)
        guard current.isEmpty || current == link.host, let url = link.webURL else { return }
        guard let found = await LinkTitles.title(for: url), !found.isEmpty else { return }
        link.title = found
        try? context.save()
    }
}
