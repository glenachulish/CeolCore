import Foundation

/// The abcjs pages, the library itself, and the bundled instrument samples.
///
/// These used to live in the iOS app and were found with `Bundle.main`. They
/// are shared now, because both apps render notation and both play it, and
/// `abc.html` in particular is 96 KB of measured engraving fixes — two copies
/// of that would diverge, and the divergence would surface as a rendering bug
/// months later with nothing to point at.
///
/// **The folder is called `Web`, not `Resources`.** `.copy` places it at the
/// top level of the built bundle, beside `Info.plist`, and on iOS — where a
/// bundle is shallow — a top-level directory named `Resources` is how
/// `codesign` recognises an old-style deep bundle. It reads the bundle as
/// malformed and refuses to sign it, which fails the build after every line of
/// Swift has compiled and says nothing about the real cause. macOS bundles are
/// deep, so the Mac app never hits it. `Package.swift` carries the longer note.
///
/// **The package must copy this folder, not process it.** `Package.swift` says
/// `.copy("Web")` deliberately. The pages load their scripts with
/// relative tags —
///
/// ```html
/// <script src="abcjs-basic-min.js"></script>
/// <script src="abctools.js"></script>
/// <script src="voices.js"></script>
/// <link href="abcjs-audio.css">
/// ```
///
/// — and `loadFileURL(_:allowingReadAccessTo:)` grants the page's containing
/// directory. `.process` may flatten or rearrange that layout, at which point
/// the scripts silently stop resolving. What you get is a blank sheet of music
/// and nothing in the console, which is a long way from the cause.
public enum CeolResources {

    /// One of the abcjs pages: "abc", "set", "noteedit", "octave", "youtube".
    ///
    /// The web view is loaded with
    /// `loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())`,
    /// which is what lets the relative script tags above resolve. Keep that
    /// pairing — granting access to the file alone loads the page and none of
    /// its scripts, and abcjs is then simply undefined.
    public static func page(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "html",
                          subdirectory: "Web")
    }

    /// A bundled instrument sample, e.g. folder "flute", note "A4".
    ///
    /// Four instruments are carried so the app plays at a session with no
    /// reception; everything else is fetched once and cached. Note the
    /// subdirectory: under `.copy` the folder structure is preserved, so these
    /// are at `Web/soundfont/`, where `Bundle.main.url(forResource:)` used to
    /// find them flattened into the app bundle's root.
    public static func soundfont(folder: String, note: String) -> URL? {
        Bundle.module.url(forResource: "\(folder)-\(note)", withExtension: "mp3",
                          subdirectory: "Web/soundfont")
    }

    /// Everything the pages need, in one directory — for the web view's
    /// read-access grant.
    public static var pagesDirectory: URL? {
        page("abc")?.deletingLastPathComponent()
    }
}
