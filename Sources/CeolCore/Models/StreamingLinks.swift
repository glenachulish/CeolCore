import Foundation

// FONN-EMBEDS-1
/// Spotify and Bandcamp links, read for playing in the strip under the music.
///
/// Neither service lets an app like Fonn drive its own player: Spotify's SDK
/// is closed to apps under 250k monthly users, and Bandcamp has no API at all.
/// What both do offer is their own embedded player, made for putting a track
/// on someone else's page. That is what plays in the strip, with the
/// service's own controls, loaded as the top-level page of a small web view so
/// that a Spotify sign-in made inside Fonn applies to it.
///
/// No model change: everything is read from the stored link, and Bandcamp's
/// numeric id (which its page links don't carry) from the page itself.
///
/// Mirrored by tools/verify_streaming_links.py. Keep the two in step.
public enum SpotifyLink {

    /// The kinds of thing Spotify's embed will play.
    static let kinds: Set<String> = ["track", "album", "playlist", "episode", "show"]

    /// `open.spotify.com/track/<id>`, `…/intl-de/track/<id>?si=…`, or a
    /// `spotify:track:<id>` URI, as kind and id. Anything else is nil.
    public static func item(from string: String) -> (kind: String, id: String)? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("spotify:") {
            let parts = s.split(separator: ":").map(String.init)
            guard parts.count == 3, kinds.contains(parts[1].lowercased()), isID(parts[2]) else { return nil }
            return (parts[1].lowercased(), parts[2])
        }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s),
              let host = comps.host?.lowercased(),
              host == "open.spotify.com" || host == "play.spotify.com" else { return nil }
        var parts = comps.path.split(separator: "/").map(String.init)
        if let first = parts.first, first.lowercased().hasPrefix("intl-") { parts.removeFirst() }
        if parts.first?.lowercased() == "embed" { parts.removeFirst() }
        guard parts.count >= 2, kinds.contains(parts[0].lowercased()), isID(parts[1]) else { return nil }
        return (parts[0].lowercased(), parts[1])
    }

    /// Spotify ids are 22 characters of base 62.
    static func isID(_ s: String) -> Bool {
        s.count == 22 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // FONN-SPOTIFYSEARCH-1
    /// Spotify's own search page.
    ///
    /// This used to go through DuckDuckGo, limited to open.spotify.com. On
    /// 6 Nov 2026 that failed repeatedly with DuckDuckGo's own error, and the
    /// unfiltered results had nothing from Spotify; Spotify's page found the
    /// tune without signing in. Spotify throws away words given in its search
    /// address (`/search/<words>`, seen 30 Oct 2026), and filling in its box by
    /// script didn't work when tried, so the person types the name there.
    public static let searchPage = URL(string: "https://open.spotify.com/search")!

    /// A page worth attaching: something the strip can play.
    public static func isPlayable(_ url: URL?) -> Bool {
        guard let url else { return false }
        return item(from: url.absoluteString) != nil
    }

    /// The embed page for a link. The compact player is 80 points tall.
    public static func embedURL(from string: String) -> URL? {
        guard let found = item(from: string) else { return nil }
        return URL(string: "https://open.spotify.com/embed/\(found.kind)/\(found.id)")
    }
}

public enum BandcampLink {

    /// A Bandcamp track or album page: `<artist>.bandcamp.com/track/<slug>`
    /// or `/album/<slug>`. Artists on their own domains aren't recognised from
    /// the address; those keep opening as a web page.
    public static func isPage(_ string: String) -> Bool {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s),
              let host = comps.host?.lowercased(),
              host.hasSuffix(".bandcamp.com") else { return false }
        let parts = comps.path.split(separator: "/").map(String.init)
        return parts.count >= 2 && (parts[0] == "track" || parts[0] == "album")
    }

    // FONN-EMBEDS-3
    /// Bandcamp's own search for some words, tracks first.
    public static func searchURL(for words: String) -> URL? {
        let collapsed = words.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return URL(string: "https://bandcamp.com/search") }
        return URL(string: "https://bandcamp.com/search?q=\(WebABC.queryEncoded(collapsed))&item_type=t")
    }

    /// A page worth attaching: a track or album page, without the query that
    /// Bandcamp adds when you arrive from its search.
    public static func playablePage(_ url: URL?) -> String? {
        guard let url, isPage(url.absoluteString),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.query = nil
        comps.fragment = nil
        return comps.url?.absoluteString
    }

    /// The player's kind ("track" or "album") and numeric id, read from a
    /// Bandcamp page.
    ///
    /// First from `<meta name="bc-page-properties">`, Bandcamp's own record of
    /// what the page is; failing that, from the embed address it advertises
    /// for sharing (`og:video`, `EmbeddedPlayer/…/track=<id>`).
    public static func embedItem(fromPage html: String) -> (kind: String, id: String)? {
        if let item = fromPageProperties(html) { return item }
        guard let range = html.range(of: #"EmbeddedPlayer/[^"'\s]*?(track|album)=(\d+)"#,
                                     options: .regularExpression) else { return nil }
        let match = String(html[range])
        for kind in ["track", "album"] {
            if let r = match.range(of: "\(kind)=") {
                let digits = match[r.upperBound...].prefix { $0.isNumber }
                if !digits.isEmpty { return (kind, String(digits)) }
            }
        }
        return nil
    }

    static func fromPageProperties(_ html: String) -> (kind: String, id: String)? {
        guard let nameRange = html.range(of: "bc-page-properties") else { return nil }
        let tail = html[nameRange.upperBound...]
        guard let contentRange = tail.range(of: "content=") else { return nil }
        let afterContent = tail[contentRange.upperBound...]
        guard let quote = afterContent.first, quote == "\"" || quote == "'" else { return nil }
        let body = afterContent.dropFirst()
        guard let end = body.firstIndex(of: quote) else { return nil }
        let json = String(body[..<end])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["item_type"] as? String else { return nil }
        let id: String
        if let n = object["item_id"] as? NSNumber { id = n.stringValue }
        else if let s = object["item_id"] as? String, !s.isEmpty, s.allSatisfy({ $0.isNumber }) { id = s }
        else { return nil }
        switch type {
        case "t": return ("track", id)
        case "a": return ("album", id)
        default:  return nil
        }
    }

    /// Bandcamp's small player: play button, title and progress, 42 points
    /// tall, which fits the strip as it is.
    public static func embedURL(kind: String, id: String, dark: Bool) -> URL? {
        let bg = dark ? "333333" : "ffffff"
        let link = dark ? "ffffff" : "0687f5"
        return URL(string: "https://bandcamp.com/EmbeddedPlayer/\(kind)=\(id)/size=small/bgcol=\(bg)/linkcol=\(link)/transparent=true/")
    }
}

/// Which service, if any, plays a link in the strip.
public enum StripService: String, Sendable {
    case appleMusic, spotify, bandcamp

    public var name: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify:    return "Spotify"
        case .bandcamp:   return "Bandcamp"
        }
    }
}

extension MediaItem {
    /// The service whose player this link opens in the strip, or nil.
    public var stripService: StripService? {
        guard kind == .link else { return nil }
        if appleMusicSongID != nil { return .appleMusic }
        if SpotifyLink.item(from: urlString) != nil { return .spotify }
        if BandcampLink.isPage(urlString) { return .bandcamp }
        return nil
    }
}

// FONN-CHIPLABEL-1
extension MediaItem {
    /// What a chip under the music calls this item when it has been named.
    ///
    /// A title from the Apple Music, Spotify or Bandcamp search is
    /// "Track — Performer"; on the tune's own page the track is the tune, so
    /// the chip says who plays it ("Lùnasa"). Any other title is used as it is.
    /// Empty means unnamed, and the chip says what kind it is.
    public static func chipName(fromTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let r = trimmed.range(of: " — ", options: .backwards) {
            let after = trimmed[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { return after }
        }
        return trimmed
    }
}
