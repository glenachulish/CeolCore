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

    /// The YouTube video id, for the three link shapes that turn up:
    /// `youtu.be/ID`, `youtube.com/watch?v=ID`, `youtube.com/shorts/ID`.
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
