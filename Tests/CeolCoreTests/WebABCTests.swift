import Testing
import Foundation
@testable import CeolCore

/// Reading notation off an arbitrary web page.
///
/// Worth testing because the input is the open web: the failure mode is not a
/// crash but a tune imported with a site's navigation menu wedged into the top
/// of it, which looks fine in a list and is nonsense when you open it.
struct WebABCTests {

    @Test("everything above the first X: is thrown away")
    func headingsAreDropped() {
        let page = """
        Home  Tunes  Sessions  Log in
        Cooley's Reel
        X:1
        T:Cooley's
        K:Edor
        E2BE B2EB|
        """
        #expect(WebABC.tidy(page).hasPrefix("X:1"))
        #expect(!WebABC.tidy(page).contains("Log in"))
    }

    /// The test for "is this notation at all". abcjs will not engrave without a
    /// key line, so a block without one is not a tune however promising the X:
    /// looked.
    @Test("a block with no key line is not a tune")
    func noKeyLineIsRejected() {
        #expect(WebABC.tidy("X:1\nT:Half a tune\nsome prose").isEmpty)
    }

    @Test("a page with no notation yields nothing")
    func noNotationYieldsNothing() {
        #expect(WebABC.tidy("Just some words about music.").isEmpty)
    }

    @Test("one tune on a page is named for the page, without a number")
    func singleSourceIsUnnumbered() {
        let sources = WebABC.sources(from: ["X:1\nK:D\nDED|"], pageTitle: "Cooley's")
        #expect(sources.count == 1)
        #expect(sources[0].name == "Cooley's")
    }

    @Test("several tunes on a page are numbered")
    func severalSourcesAreNumbered() {
        let sources = WebABC.sources(
            from: ["X:1\nK:D\nDED|", "X:2\nK:G\nGAB|"],
            pageTitle: "Session tunes")
        #expect(sources.map(\.name) == ["Session tunes (1)", "Session tunes (2)"])
    }

    @Test("blocks that are not notation are dropped, and do not take a number with them")
    func rubbishBlocksAreDropped() {
        let sources = WebABC.sources(
            from: ["Advertisement", "X:1\nK:D\nDED|"],
            pageTitle: "Tunes")
        #expect(sources.count == 1)
    }

    @Test("a page with no title still names its tunes something")
    func untitledPage() {
        let sources = WebABC.sources(from: ["X:1\nK:D\nDED|"], pageTitle: "")
        #expect(sources[0].name == "Web page")
    }

    // MARK: - The address bar

    @Test("a bare hostname is assumed to be https")
    func bareHostGetsSecureScheme() {
        #expect(WebABC.address(from: "tunearch.org")?.absoluteString == "https://tunearch.org")
    }

    @Test("a scheme already given is left alone")
    func schemeIsLeftAlone() {
        #expect(WebABC.address(from: "http://example.org")?.scheme == "http")
    }

    @Test("nothing typed is no address")
    func emptyIsNil() {
        #expect(WebABC.address(from: "   ") == nil)
    }

    // MARK: - The search bar (FONN-WEBSEARCH-1)

    @Test("an empty bar opens the chosen site's search page")
    func blankGoesHome() {
        let site = WebABC.site(id: "gatherer")
        #expect(WebABC.destination(for: "  ", site: site)?.absoluteString
                == "https://nigelgatherer.com/tunes/abc.html")
    }

    @Test("words search the chosen site")
    func wordsSearchTheSite() {
        let url = WebABC.destination(for: "Cooley's  reel", site: WebABC.site(id: "session"))
        #expect(url?.absoluteString == "https://thesession.org/tunes/search?q=Cooley%27s+reel")
    }

    @Test("an address typed goes straight there, whichever site is chosen")
    func addressBeatsSite() {
        let url = WebABC.destination(for: "nigelgatherer.com/tunes/abc/abc1.html",
                                     site: WebABC.site(id: "tunearch"))
        #expect(url?.absoluteString == "https://nigelgatherer.com/tunes/abc/abc1.html")
    }

    @Test("a title with a full stop and a space is words, not a host")
    func titleWithDotIsWords() {
        #expect(WebABC.interpret("St. Anne's Reel") == .words("St. Anne's Reel"))
        #expect(WebABC.interpret("reel.") == .words("reel."))
        #expect(WebABC.interpret("1.2") == .words("1.2"))
    }

    @Test("an unknown stored site falls back to the first")
    func unknownSite() {
        #expect(WebABC.site(id: "gone").id == WebABC.sites[0].id)
    }

    // MARK: - .abc files (FONN-WEBSEARCH-2)

    @Test("a link to an .abc file is recognised")
    func abcFileLink() {
        #expect(WebABC.isABCFile(URL(string: "https://nigelgatherer.com/tunes/abc/abc10/hroad.abc")!))
        #expect(!WebABC.isABCFile(URL(string: "https://nigelgatherer.com/tunes/abc.html")!))
    }

    @Test("a fetched file is named by its first title")
    func fileNamedByTitle() {
        let url = URL(string: "https://example.org/abc/hroad.abc")!
        let sources = WebABC.sources(fromFile: "%comment\nX:1\nT:High Road to Linton\nK:A\nAB|", url: url)
        #expect(sources.count == 1)
        #expect(sources[0].name == "High Road to Linton")
        #expect(sources[0].text.hasPrefix("X:1"))
    }

    // MARK: - What the page hands back

    @Test("malformed JSON from the page is no blocks rather than a crash")
    func malformedJSONIsSurvivable() {
        #expect(WebABC.blocks(fromJSON: "not json").isEmpty)
        #expect(WebABC.blocks(fromJSON: nil).isEmpty)
    }

    @Test("well-formed JSON comes back as its blocks")
    func wellFormedJSON() {
        #expect(WebABC.blocks(fromJSON: #"["one","two"]"#) == ["one", "two"])
    }
}
