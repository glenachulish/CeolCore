import Testing
@testable import CeolCore

// FONN-EMBEDS-1
@Suite("Spotify and Bandcamp links")
struct StreamingLinksTests {

    @Test("a Spotify track link gives its kind and id")
    func spotifyTrack() {
        let item = SpotifyLink.item(from: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc")
        #expect(item?.kind == "track")
        #expect(item?.id == "4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test("an intl- prefix and a spotify: URI are both read")
    func spotifyVariants() {
        #expect(SpotifyLink.item(from: "https://open.spotify.com/intl-de/album/1A2GTWGtFfWp7KSQTwWOyo")?.kind == "album")
        #expect(SpotifyLink.item(from: "spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.id == "4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test("the embed address is built from the link")
    func spotifyEmbed() {
        #expect(SpotifyLink.embedURL(from: "open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")?.absoluteString
                == "https://open.spotify.com/embed/track/4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test("an artist page or a short id is not playable")
    func spotifyRejects() {
        #expect(SpotifyLink.item(from: "https://open.spotify.com/artist/0OdUWJ0sBjDrqHygGUXeCF") == nil)
        #expect(SpotifyLink.item(from: "https://open.spotify.com/track/short") == nil)
        #expect(SpotifyLink.item(from: "https://example.com/track/4uLU6hMCjMI75M1A2tKUQC") == nil)
    }

    @Test("Bandcamp track and album pages are recognised; the artist's front page is not")
    func bandcampPages() {
        #expect(BandcampLink.isPage("https://michaelmcgoldrick.bandcamp.com/track/the-wiggly-jig"))
        #expect(BandcampLink.isPage("michaelmcgoldrick.bandcamp.com/album/arcadia"))
        #expect(!BandcampLink.isPage("https://michaelmcgoldrick.bandcamp.com/"))
        #expect(!BandcampLink.isPage("https://bandcamp.com/discover"))
    }

    @Test("the id comes from bc-page-properties")
    func bandcampPageProperties() {
        let html = #"<meta name="bc-page-properties" content="{&quot;item_type&quot;:&quot;t&quot;,&quot;item_id&quot;:2797651047,&quot;tralbum_page_version&quot;:0}">"#
        let item = BandcampLink.embedItem(fromPage: html)
        #expect(item?.kind == "track")
        #expect(item?.id == "2797651047")
    }

    @Test("failing that, from the advertised embed address")
    func bandcampOgVideo() {
        let html = #"<meta property="og:video" content="https://bandcamp.com/EmbeddedPlayer/v=2/album=1234567/size=large/tracklist=false/artwork=small/">"#
        let item = BandcampLink.embedItem(fromPage: html)
        #expect(item?.kind == "album")
        #expect(item?.id == "1234567")
    }

    @Test("search pages for both services (FONN-EMBEDS-3)")
    func searchURLs() {
        #expect(SpotifyLink.searchPage.absoluteString == "https://open.spotify.com/search")
        #expect(BandcampLink.searchURL(for: "McGoldrick reels")?.absoluteString
                == "https://bandcamp.com/search?q=McGoldrick+reels&item_type=t")
        #expect(BandcampLink.searchURL(for: " ")?.absoluteString == "https://bandcamp.com/search")
    }

    @Test("a Bandcamp page found through search is stored without the search's query")
    func bandcampPlayablePage() {
        let url = URL(string: "https://michaelmcgoldrick.bandcamp.com/track/the-wiggly-jig?from=search&search_item_id=1")
        #expect(BandcampLink.playablePage(url) == "https://michaelmcgoldrick.bandcamp.com/track/the-wiggly-jig")
        #expect(BandcampLink.playablePage(URL(string: "https://bandcamp.com/search?q=x")) == nil)
    }

    @Test("a chip is named by the performer, or by the title as given (FONN-CHIPLABEL-1)")
    func chipNames() {
        #expect(MediaItem.chipName(fromTitle: "The Kesh Jig — Lùnasa") == "Lùnasa")
        #expect(MediaItem.chipName(fromTitle: "Live in Ennis") == "Live in Ennis")
        #expect(MediaItem.chipName(fromTitle: "  ") == nil)
        #expect(MediaItem.chipName(fromTitle: "Jig — ") == "Jig —")
    }

    @Test("a page with neither gives nothing")
    func bandcampNothing() {
        #expect(BandcampLink.embedItem(fromPage: "<html><body>hello</body></html>") == nil)
    }
}
