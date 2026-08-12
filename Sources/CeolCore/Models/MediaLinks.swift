import Foundation

/// What a linked attachment actually points at, and whether it can work here.
///
/// The Pi stored links as whatever URL was to hand at the time, which included
/// addresses that only ever resolved on the Pi itself. Those came across in the
/// migration and will never load on a phone; better to say so than to leave you
/// tapping them.
extension MediaItem {

    public enum LinkHealth: Sendable {
        /// A public address that should just work.
        case fine
        /// `localhost` — only ever resolvable on the machine serving it.
        case deviceOnly
        /// Reachable, but only with Tailscale up.
        case vpnOnly
        /// A share link with a limited life, e.g. iCloud.
        case temporary

        public var warning: String? {
            switch self {
            case .fine:       return nil
            case .deviceOnly: return "Only works on the Pi itself"
            case .vpnOnly:    return "Needs Tailscale"
            case .temporary:  return "Share link — may have expired"
            }
        }
    }

    public var linkHealth: LinkHealth {
        guard kind == .link || !urlString.isEmpty,
              let host = webURL?.host?.lowercased() else { return .fine }
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
            return .deviceOnly
        }
        if host.hasSuffix(".ts.net") { return .vpnOnly }
        if host.contains("icloud-content.com") { return .temporary }
        return .fine
    }

    /// A link straight to an audio or video file, as opposed to a web page.
    /// These can be played in the app with the same speed control as a local
    /// recording, rather than handed off to a web view.
    public var isDirectMedia: Bool {
        guard let url = webURL else { return false }
        let ext = url.deletingPathExtension().pathExtension.isEmpty
            ? url.pathExtension.lowercased()
            : url.pathExtension.lowercased()
        return ["mp3", "m4a", "wav", "ogg", "aac", "flac",
                "mp4", "mov", "webm", "m4v"].contains(ext)
    }

    public var isDirectVideo: Bool {
        guard let url = webURL else { return false }
        return ["mp4", "mov", "webm", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// The YouTube video id, for the three link shapes that turn up:
    /// `youtu.be/ID`, `youtube.com/watch?v=ID`, `youtube.com/shorts/ID`.
    public var youTubeID: String? {
        guard let url = webURL else { return nil }
        return MediaLinks.youTubeID(of: url)
    }

    /// A web address you listen to, rather than a file this app holds.
    ///
    /// Distinct from `.audio` alone, which is mostly the 307 recordings kept
    /// on disk. This is the handful that live somewhere else — a Bandcamp
    /// page, an mp3 on flutefling.scot — and are therefore only there when you
    /// have a signal.
    public var isAudioLink: Bool {
        guard filename.isEmpty, let url = webURL, !MediaLinks.isLocalOnly(url) else {
            return false
        }
        return kind == .audio || MediaLinks.isAudio(url)
    }

    /// Where to play from: the local file if there is one, otherwise a direct
    /// media URL. Nil means it isn't playable in the app.
    public var playbackURL: URL? {
        if let fileURL { return fileURL }
        return isDirectMedia ? webURL : nil
    }
}

/// Link facts that do not need a `MediaItem` behind them.
///
/// A URL sitting in a tune's notes is not an attachment yet, but it is still a
/// YouTube link and should still play in the app rather than being thrown at a
/// browser. Pulling this out of the `MediaItem` extension is what lets the same
/// player serve both.
public enum MediaLinks {

    /// Somewhere you listen rather than watch.
    ///
    /// Two shapes: a direct audio file on the web, and the streaming services
    /// a tune gets linked to. Both are "an audio link" as far as anyone
    /// looking for one is concerned.
    public static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg"].contains(ext) {
            return true
        }
        let host = (url.host ?? "").lowercased()
        return host.contains("bandcamp.com")
            || host.contains("soundcloud.com")
            || host.contains("music.apple.com")
            || host.contains("open.spotify.com")
    }

    /// An address that only ever worked on the machine it was written on.
    ///
    /// The web app wrote its own address into a tune's notes: 11 of this
    /// library's audio links point at `localhost:8001` or the Pi over
    /// Tailscale. They look like recordings you can play and are dead
    /// everywhere else, so nothing should offer them.
    public static func isLocalOnly(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "localhost"
            || host == "127.0.0.1"
            || host.hasSuffix(".local")
            || host.hasSuffix(".ts.net")
            || host.contains("icloud-content.com")
    }

    /// The same address over https.
    ///
    /// The Pi's notes carry `http://www.youtube.com/watch?v=…` — plain http,
    /// because that is what was pasted in years ago. App Transport Security
    /// refuses an insecure load outright, so a web view handed that URL shows
    /// nothing and reports nothing. Every host worth reaching serves https.
    public static func secured(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.scheme = "https"
        return parts.url ?? url
    }

    /// How to put a link on screen.
    public enum Embed {
        /// Load this address as a page.
        case page(URL)
        /// Load this markup, telling the web view it came from `base`.
        case markup(String, base: URL)
    }

    /// What to hand a web view for a link.
    ///
    /// YouTube's player refuses to run without a valid origin — it answers
    /// **Error 153, "Video player configuration error"**. A WKWebView loading
    /// `youtube-nocookie.com/embed/…` as a top-level page sends no Referer and
    /// presents no origin, so it is refused every time.
    ///
    /// The iframe wrapped in `loadHTMLString(_:baseURL:)` is not a workaround
    /// for a file:// problem that could be skipped: giving the markup a real
    /// base URL *is* how the origin gets supplied. I removed it on the theory
    /// that loading the page directly was cleaner, and earned Error 153 on
    /// every video. It is back, and this comment is here so it does not get
    /// removed again.
    ///
    /// The https upgrade stays, because that part was a real fault: the notes
    /// are full of `http://` addresses and App Transport Security refuses them
    /// silently.
    public static func embed(for url: URL) -> Embed {
        guard let id = youTubeID(of: url) else { return .page(secured(url)) }
        let html = """
            <html><body style="margin:0;background:#000">
            <iframe width="100%" height="100%" style="border:0"
              src="https://www.youtube-nocookie.com/embed/\(id)?playsinline=1&rel=0"
              allow="autoplay; encrypted-media" allowfullscreen></iframe>
            </body></html>
            """
        return .markup(html, base: URL(string: "https://www.youtube.com")!)
    }

    public static func youTubeID(of url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }
        if url.path.hasPrefix("/shorts/") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value
    }
}
