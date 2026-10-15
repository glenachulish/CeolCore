import Testing
import Foundation
import SwiftData
@testable import CeolCore

/// The Fonn ↔ Tobar link rules. The same cases are mirrored, without Swift,
/// by tools/verify_tobar_link.py — keep the two in step.
struct TobarLinkTests {

    // MARK: Track links

    @Test("track ids are read from Tobar an Dualchais track pages only")
    func trackIDs() {
        #expect(TobarLink.trackID(from: "https://www.tobarandualchais.co.uk/track/91825?l=en") == 91825)
        #expect(TobarLink.trackID(from: "https://tobarandualchais.co.uk/track/1") == 1)
        #expect(TobarLink.trackID(from: "www.tobarandualchais.co.uk/track/42") == 42)
        #expect(TobarLink.trackID(from: "  https://www.tobarandualchais.co.uk/track/7/  ") == 7)
        #expect(TobarLink.trackID(from: "https://www.tobarandualchais.co.uk/person/12") == nil)
        #expect(TobarLink.trackID(from: "https://www.tobarandualchais.co.uk/track/abc") == nil)
        #expect(TobarLink.trackID(from: "https://example.com/track/91825") == nil)
        #expect(TobarLink.trackID(from: "") == nil)
    }

    @Test("the same track in two spellings is the same track")
    func sameTrack() {
        #expect(TobarLink.sameTrack("https://www.tobarandualchais.co.uk/track/91825?l=en",
                                    "http://tobarandualchais.co.uk/track/91825"))
        #expect(!TobarLink.sameTrack("https://www.tobarandualchais.co.uk/track/1",
                                     "https://www.tobarandualchais.co.uk/track/2"))
        #expect(!TobarLink.sameTrack("https://example.com/track/1",
                                     "https://example.com/track/1"))
    }

    // MARK: Fonn → Tobar

    @Test("Open in Tobar sends tobar://add with the link and the title")
    func openInTobar() throws {
        let url = try #require(TobarLink.openInTobarURL(
            link: " https://www.tobarandualchais.co.uk/track/1 ", title: "Fear a' Bhàta"))
        #expect(url.scheme == "tobar")
        #expect(url.host == "add")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "link" }?.value == "https://www.tobarandualchais.co.uk/track/1")
        #expect(items.first { $0.name == "title" }?.value == "Fear a' Bhàta")
        #expect(TobarLink.appStoreURL?.absoluteString == "https://apps.apple.com/app/id6818873213")
    }

    // MARK: Tobar → Fonn

    @Test("fonn://tune carries a title and a track link")
    func parseTune() throws {
        let url = try #require(URL(string:
            "fonn://tune?title=The%20Banshee&link=https%3A%2F%2Fwww.tobarandualchais.co.uk%2Ftrack%2F1"))
        let incoming = try #require(TobarLink.parseIncoming(url))
        #expect(incoming.title == "The Banshee")
        #expect(incoming.link == "https://www.tobarandualchais.co.uk/track/1")
    }

    @Test("the older fonn://search is the same thing with no link")
    func parseSearch() throws {
        let url = try #require(URL(string: "fonn://search?q=Calliope%20House"))
        #expect(TobarLink.parseIncoming(url) == TobarLink.Incoming(title: "Calliope House", link: nil))
    }

    @Test("a link that isn't a Tobar track is dropped, the title kept")
    func parseNonTrackLink() throws {
        let url = try #require(URL(string: "fonn://tune?title=Kesh&link=https%3A%2F%2Fexample.com%2Ftrack%2F1"))
        #expect(TobarLink.parseIncoming(url) == TobarLink.Incoming(title: "Kesh", link: nil))
    }

    @Test("anything else is left alone")
    func parseOthers() {
        let others = [
            "fonn://tune?link=https%3A%2F%2Fwww.tobarandualchais.co.uk%2Ftrack%2F1",
            "fonn://tune?title=%20%20",
            "fonn://set?title=Kesh",
            "orain://song?title=Kesh",
            "file:///Users/me/library.ceol.json",
            "https://www.tobarandualchais.co.uk/track/1",
        ]
        for string in others {
            #expect(TobarLink.parseIncoming(URL(string: string)!) == nil, "\(string)")
        }
    }

    // MARK: Matching titles

    @Test("titles match with accents, case, articles and punctuation ignored")
    func matchKeys() {
        let same: [(String, String)] = [
            ("The Banshee", "Banshee, The"),
            ("the banshee", "Banshee"),
            ("Chì Mi Na Mòrbheanna", "chi mi na morbheanna"),
            ("An t-Eilean Muileach", "Eilean Muileach"),
            ("Eilean Muileach, An t-", "An t-Eilean Muileach"),
            ("Fear a' Bhàta", "Fear a Bhata"),
            ("Morrison's Jig", "Morrison’s Jig"),
            ("  Kesh   Jig  ", "Kesh Jig"),
        ]
        for (a, b) in same {
            #expect(TobarLink.matchKey(a) == TobarLink.matchKey(b), "\(a) / \(b)")
        }
        #expect(TobarLink.matchKey("Kesh Jig") != TobarLink.matchKey("Kesh"))
        #expect(TobarLink.matchKey("The") == "the")
    }

    @Test("matching is exact on the key — no near misses")
    func matchIndex() {
        let titles = ["Kesh Jig", "Banshee, The", "Morrison's Jig"]
        #expect(TobarLink.matchIndex(for: "The Banshee", in: titles) == 1)
        #expect(TobarLink.matchIndex(for: "morrison’s jig", in: titles) == 2)
        #expect(TobarLink.matchIndex(for: "Kesh", in: titles) == nil)
        #expect(TobarLink.matchIndex(for: "", in: titles) == nil)
    }

    // MARK: The library

    private func library() throws -> ModelContext {
        let container = try ModelContainer(
            for: Tune.self, TuneSet.self, SetEntry.self,
                TuneCollection.self, MediaItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func all(_ context: ModelContext) throws -> [Tune] {
        try context.fetch(FetchDescriptor<Tune>())
    }

    @Test("a tune is found by title, and a grouped tune by its default")
    func findsTheShownTune() throws {
        let context = try library()
        let a = Tune(title: "Banshee, The")
        let b = Tune(title: "Banshee, The")
        let group = UUID()
        a.groupID = group; a.isDefaultVersion = false
        b.groupID = group; b.isDefaultVersion = true
        context.insert(a); context.insert(b)
        try context.save()

        let found = TobarLink.findTune(titled: "The Banshee", in: try all(context), context: context)
        #expect(found === b)
        #expect(TobarLink.findTune(titled: "Banshees", in: try all(context), context: context) == nil)
    }

    @Test("an alias finds the tune when no title does")
    func findsByAlias() throws {
        let context = try library()
        let t = Tune(title: "Calliope House")
        t.aliases = ["Taigh Calliope"]
        context.insert(t)
        try context.save()
        #expect(TobarLink.findTune(titled: "taigh calliope", in: try all(context), context: context) === t)
    }

    @Test("the link is added once, compared by track number")
    func attachesOnce() throws {
        let context = try library()
        let t = Tune(title: "Kesh Jig")
        context.insert(t)
        try context.save()

        #expect(TobarLink.attach("https://www.tobarandualchais.co.uk/track/5?l=en", to: t, context: context))
        #expect(!TobarLink.attach("http://tobarandualchais.co.uk/track/5", to: t, context: context))
        #expect((t.media ?? []).count == 1)
        #expect(TobarLink.attach("https://www.tobarandualchais.co.uk/track/6", to: t, context: context))
        #expect((t.media ?? []).count == 2)
        #expect(!TobarLink.attach("https://example.com/track/7", to: t, context: context))
    }

    @Test("a track already on another version, or as the source, is not added again")
    func respectsTheWholeGroup() throws {
        let context = try library()
        let shown = Tune(title: "Kesh Jig")
        let other = Tune(title: "Kesh Jig")
        let group = UUID()
        shown.groupID = group; other.groupID = group; other.isDefaultVersion = false
        other.sourceURL = "https://www.tobarandualchais.co.uk/track/9"
        context.insert(shown); context.insert(other)
        try context.save()

        #expect(TobarLink.hasTrack("https://www.tobarandualchais.co.uk/track/9?l=gd", tune: shown, context: context))
        #expect(!TobarLink.attach("https://www.tobarandualchais.co.uk/track/9", to: shown, context: context))
    }

    @Test("adding a tune that isn't there attaches the link")
    func addsATune() throws {
        let context = try library()
        let incoming = TobarLink.Incoming(title: "Fear a' Bhàta",
                                          link: "https://www.tobarandualchais.co.uk/track/3")
        let made = try #require(TobarLink.addTune(incoming, context: context))
        #expect(made.title == "Fear a' Bhàta")
        #expect((made.media ?? []).map(\.urlString) == ["https://www.tobarandualchais.co.uk/track/3"])
        #expect(TobarLink.trackLinks(of: made) == ["https://www.tobarandualchais.co.uk/track/3"])
    }
}
