import Foundation

// FONN-APPLEMUSIC-1
/// Apple Music catalogue songs, read from the links already stored on tunes.
///
/// No model change: the song's catalogue id is in the address itself, so it
/// is worked out each time rather than stored. Two shapes carry it:
///
///     music.apple.com/gb/album/<name>/969195822?i=969196002   a track on an album page
///     music.apple.com/gb/song/<name>/969196002                a song page
///
/// An album link with no `?i=` is a whole album, not a tune, and gives nil,
/// as do playlists, artists and anything that is not Apple Music. Those keep
/// the old behaviour of handing the link to the Music app. The older
/// itunes.apple.com addresses use the same `?i=` and are accepted too.
///
/// The storefront in the address (`gb`) is deliberately ignored: MusicKit
/// looks songs up in the listener's own storefront.
///
/// Mirrored by tools/verify_apple_music_link.py. Keep the two in step.
public enum AppleMusicLink {

    public static func songID(from string: String) -> String? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s),
              let host = comps.host?.lowercased(),
              isAppleMusicHost(host) else { return nil }
        if let i = comps.queryItems?.first(where: { $0.name == "i" })?.value {
            return isCatalogueID(i) ? i : nil
        }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.contains("song"), let last = parts.last, isCatalogueID(last) else {
            return nil
        }
        return last
    }

    public static func isAppleMusicHost(_ host: String) -> Bool {
        host == "music.apple.com"
            || host.hasSuffix(".music.apple.com")
            || host == "itunes.apple.com"
    }

    /// Catalogue ids are plain digits. Library ids (`i.xxxx`) never appear in
    /// a shared link, and would not play for anyone else if they did.
    static func isCatalogueID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 20 && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

extension MediaItem {
    /// The Apple Music catalogue song this attachment links to, or nil.
    public var appleMusicSongID: String? { AppleMusicLink.songID(from: urlString) }
}
