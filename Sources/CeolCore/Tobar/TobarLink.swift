//  TobarLink.swift
//  CeolCore
//
//  The two links between Fonn and Tobar, the same pair Òrain has
//  (OrainCore/TobarLink.swift, 14–15 Oct 2026):
//
//  - Tobar → Fonn: `fonn://tune?title=<title>&link=<track page>`.
//    Fonn opens the tune with that title. If the tune hasn't got that Tobar
//    an Dualchais track yet, the link is added to it. If there is no such
//    tune, Fonn offers to add one, through the free-tune limit.
//    The older `fonn://search?q=<title>` (what Tobar sent before) is read as
//    the same thing with no link.
//
//  - Fonn → Tobar: on a Tobar an Dualchais track link, "Open in Tobar" sends
//    `tobar://add?link=<track page>&title=<title>`. Tobar shows the bookmark
//    if it has it, or offers to save it. If Tobar isn't installed the open is
//    refused, and Fonn offers the App Store or the page in the browser.
//
//  Link formats: ~/Apple Apps/Tobar/docs/PARTNER-APPS.md.

import Foundation
import SwiftData

public enum TobarLink {

    public static let hosts: Set<String> = ["tobarandualchais.co.uk", "www.tobarandualchais.co.uk"]

    // MARK: Recognising a Tobar an Dualchais track

    /// The track number in a Tobar an Dualchais track link, e.g.
    /// `https://www.tobarandualchais.co.uk/track/91825?l=en` → 91825.
    /// Same rule as Tobar's own `TobarURL.trackID` and Òrain's copy of it.
    public static func trackID(from string: String) -> Int? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s),
              let host = comps.host?.lowercased(), hosts.contains(host) else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "track", let id = Int(parts[1]) else { return nil }
        return id
    }

    public static func isTrack(_ string: String) -> Bool { trackID(from: string) != nil }

    /// Two links to the same track, whatever their language, scheme or
    /// spelling — compared by track number, never as raw URLs.
    public static func sameTrack(_ a: String, _ b: String) -> Bool {
        guard let x = trackID(from: a), let y = trackID(from: b) else { return false }
        return x == y
    }

    // MARK: Fonn → Tobar

    /// Tobar's Apple ID in App Store Connect (App Information → Apple ID).
    /// Set to nil to hide "Get Tobar on the App Store" and offer only the page.
    public static let appStoreID: String? = "6818873213"

    /// Tobar's App Store page. An https link: on iOS and macOS it opens the
    /// App Store app directly.
    public static var appStoreURL: URL? {
        appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)") }
    }

    public static func openInTobarURL(link: String, title: String) -> URL? {
        var c = URLComponents()
        c.scheme = "tobar"
        c.host = "add"
        c.queryItems = [
            URLQueryItem(name: "link", value: link.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "title", value: title),
        ]
        return c.url
    }

    /// The track page itself, for "Open the page in the browser".
    public static func webURL(for link: String) -> URL? {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }

    // MARK: Tobar → Fonn

    public struct Incoming: Equatable, Sendable {
        public let title: String
        /// The Tobar an Dualchais track page, when one came with it and it
        /// really is a track link.
        public let link: String?

        public init(title: String, link: String?) {
            self.title = title
            self.link = link
        }
    }

    /// Reads `fonn://tune?title=…&link=…` and the older `fonn://search?q=…`.
    /// Anything else — a library file being opened, another host, no title —
    /// gives nil and is left alone.
    public static func parseIncoming(_ url: URL) -> Incoming? {
        guard url.scheme?.lowercased() == "fonn",
              let host = url.host?.lowercased(), host == "tune" || host == "search",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let raw = items.first(where: { $0.name == "title" })?.value
            ?? items.first(where: { $0.name == "q" })?.value
            ?? ""
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let link = items.first(where: { $0.name == "link" })?.value
            .flatMap { isTrack($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        return Incoming(title: title, link: link)
    }

    // MARK: Matching a title

    /// Leading articles dropped before comparing — Òrain's list, so a title
    /// Tobar sends to both apps is matched the same way by each.
    private static let leadingArticles = [
        "an t-", "an t\u{2019}", "the ", "an ", "am ", "na ", "a' ", "a\u{2019} ", "a ",
    ]

    /// Articles Fonn's library writes after a comma, in the filing form
    /// ("Banshee, The", "Eilean Muileach, An t-").
    private static let trailingArticles = ["the", "a", "an", "na", "am", "an t-", "na h-"]

    /// The form two titles are compared in: accents and case folded, a
    /// leading article dropped (or a trailing one in Fonn's filing form),
    /// punctuation ignored, spaces collapsed. So "The Banshee", "Banshee, The"
    /// and "banshee" all match, and "An t-Eilean Muileach" matches
    /// "Eilean Muileach".
    public static func matchKey(_ title: String) -> String {
        var folded = fold(title).trimmingCharacters(in: .whitespacesAndNewlines)

        if let comma = folded.lastIndex(of: ",") {
            let head = folded[..<comma].trimmingCharacters(in: .whitespaces)
            let tail = folded[folded.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, trailingArticles.contains(tail) { folded = head }
        }
        for article in leadingArticles where folded.hasPrefix(article) {
            let rest = folded.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { folded = rest }
            break
        }
        let kept = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Accents off, lower case. Done by hand rather than with
    /// `folding(options:locale:)` so the result does not depend on the
    /// device's language — the same rule as Òrain's `foldedTitle`.
    static func fold(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars).lowercased()
    }

    /// The index of the title that matches, or nil. Exact on the match key
    /// only — a near miss is not the same tune, and opening the wrong one (and
    /// adding a link to it) would be worse than asking.
    public static func matchIndex(for title: String, in titles: [String]) -> Int? {
        let wanted = matchKey(title)
        guard !wanted.isEmpty else { return nil }
        return titles.firstIndex { matchKey($0) == wanted }
    }

    // MARK: The library side

    /// The tune a title names, as the library shows it: the default of its
    /// version group. Titles first, and the shown versions before the rest;
    /// then the names a tune is also known as (grouping keeps each setting's
    /// old title as an alias). Still exact on the match key — no near misses.
    public static func findTune(titled title: String, in tunes: [Tune],
                                context: ModelContext) -> Tune? {
        let wanted = matchKey(title)
        guard !wanted.isEmpty else { return nil }
        let listed = tunes.filter { $0.groupID == nil || $0.isDefaultVersion }
        let others = tunes.filter { !($0.groupID == nil || $0.isDefaultVersion) }
        let byTitle = listed.first { matchKey($0.title) == wanted }
            ?? others.first { matchKey($0.title) == wanted }
        let found = byTitle ?? (listed + others).first { tune in
            tune.aliases.contains { matchKey($0) == wanted }
        }
        return found.map { VersionTools.shown($0, in: context) }
    }

    /// Whether any version of this tune already has that track — as its
    /// source, or as an attachment.
    public static func hasTrack(_ link: String, tune: Tune, context: ModelContext) -> Bool {
        VersionTools.versions(of: tune, in: context).contains { version in
            sameTrack(version.sourceURL, link)
                || (version.media ?? []).contains { sameTrack($0.urlString, link) }
        }
    }

    /// Add the Tobar track to the tune as a link attachment, unless some
    /// version of it already has that track. Returns whether it added one.
    @discardableResult
    public static func attach(_ link: String, to tune: Tune, context: ModelContext) -> Bool {
        guard isTrack(link), !hasTrack(link, tune: tune, context: context) else { return false }
        let item = MediaItem(kind: .link, title: "Tobar an Dualchais",
                             urlString: link.trimmingCharacters(in: .whitespacesAndNewlines))
        item.tune = tune
        context.insert(item)
        tune.updatedAt = Date()
        try? context.save()
        return true
    }

    /// A new tune for a title Tobar sent, with its track attached. Goes
    /// through the free version's allowance like every other new tune: nil
    /// means refused, and the unlock screen has been asked for.
    public static func addTune(_ incoming: Incoming, context: ModelContext) -> Tune? {
        guard TuneAllowance.shared.admit() else { return nil }
        let tune = Tune(title: incoming.title)
        context.insert(tune)
        try? context.save()
        if let link = incoming.link { attach(link, to: tune, context: context) }
        return tune
    }

    /// The title to send with an attachment's "Open in Tobar": the tune it
    /// hangs off (spoken form — "The Banshee", not "Banshee, The"), or the set.
    public static func title(for item: MediaItem) -> String {
        if let tune = item.tune { return TitleDisplay.spoken(tune.title) }
        if let set = item.tuneSet { return set.name }
        return item.title
    }

    /// Every Tobar an Dualchais track link on a tune, for "Open in Tobar":
    /// its source, then its attachments, without repeats.
    public static func trackLinks(of tune: Tune) -> [String] {
        var out: [String] = []
        let candidates = [tune.sourceURL] + (tune.media ?? []).map(\.urlString)
        for link in candidates where isTrack(link) {
            if !out.contains(where: { sameTrack($0, link) }) { out.append(link) }
        }
        return out
    }
}
