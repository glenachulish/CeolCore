import Foundation

/// Pulling ABC off an ordinary web page.
///
/// thesession.org has an API and settings worth choosing between, so it gets
/// its own screen on both platforms. Everywhere else — tunearch, irishtune.info,
/// a session's own page, somebody's blog — there is no API and no agreement
/// about layout, but there is one near-universal convention: ABC is published
/// as text, usually inside a `<pre>`, `<code>` or `<textarea>`.
///
/// The knowledge of *where notation hides on a page* and *what to throw away
/// once you have it* is the whole of this route, and it is the same knowledge
/// on a phone and on a Mac. It lives here so there is one copy: the two apps
/// differ in how a web view is wrapped, which is plumbing, and not in what
/// counts as a tune, which is a decision.
public enum WebABC {

    /// Where ABC actually lives on a page.
    ///
    /// Preformatted blocks, code blocks and editor textareas first. Only if
    /// none of those hold notation is the whole page read, because reading the
    /// body drags the site's navigation and headings in with it — recoverable,
    /// since `tidy` throws away everything above the first `X:`, but worth
    /// avoiding when a page has given us somewhere better to look.
    public static let extractionScript = """
    (function () {
      var out = [];
      var nodes = document.querySelectorAll('pre, code, textarea');
      for (var i = 0; i < nodes.length; i++) {
        var t = nodes[i].innerText || nodes[i].value || '';
        if (/^\\s*X:/m.test(t) && /^\\s*K:/m.test(t)) out.push(t);
      }
      if (!out.length) {
        var body = document.body ? (document.body.innerText || '') : '';
        if (/^\\s*X:/m.test(body) && /^\\s*K:/m.test(body)) out.push(body);
      }
      return JSON.stringify(out);
    })();
    """

    /// Decode what the script returned. Anything unexpected is no blocks rather
    /// than a crash — this is arbitrary web pages, and being wrong about one is
    /// normal.
    public static func blocks(fromJSON json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let blocks = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return blocks
    }

    /// Throw away everything before the first `X:` line, and reject anything
    /// with no `K:` in it.
    ///
    /// A page's whole text can arrive when the notation is not in a block of
    /// its own, and the navigation and headings above it are not part of the
    /// tune. `K:` is the test for whether what is left is notation at all:
    /// abcjs will not engrave without one, so a block lacking it is not a tune
    /// however promising the `X:` looked.
    public static func tidy(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("X:")
        }) else { return "" }
        let body = lines[start...].joined(separator: "\n")
        guard body.contains("K:") else { return "" }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turn what a page yielded into sources the importer can review.
    ///
    /// Named from the page's title, numbered only when there is more than one,
    /// because "Cooley's (1)" on a page holding a single tune is noise.
    public static func sources(from blocks: [String], pageTitle: String) -> [ABCImportPlan.Source] {
        let name = pageTitle.isEmpty ? "Web page" : pageTitle
        return blocks.enumerated().compactMap { index, text in
            let tidied = tidy(text)
            guard !tidied.isEmpty else { return nil }
            return ABCImportPlan.Source(
                name: blocks.count == 1 ? name : "\(name) (\(index + 1))",
                text: tidied)
        }
    }

    /// Said when a page yields nothing, in both apps.
    public static let nothingFoundMessage = """
        Fonn couldn't find any ABC notation on that page. It looks for notation \
        published as text — a page that only shows a picture of the music, or \
        notation drawn by a plug-in, has nothing to read.
        """

    // FONN-WEBSEARCH-1
    /// A site the search bar can search, and where it starts when nothing is
    /// typed.
    ///
    /// `search` is an address with `{q}` where the words go. Sites with no
    /// search of their own (Nigel Gatherer, Norbeck) are searched through
    /// DuckDuckGo limited to that site, which finds tunes on them better than
    /// browsing their indexes does. irishtune.info was dropped: it indexes
    /// recordings and books but publishes no ABC, so Find ABC never found
    /// anything there.
    public struct Site: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let home: String
        public let search: String

        public init(id: String, name: String, home: String, search: String) {
            self.id = id
            self.name = name
            self.home = home
            self.search = search
        }

        /// Where the words go for this site.
        public func searchURL(for words: String) -> URL? {
            URL(string: search.replacingOccurrences(of: "{q}", with: WebABC.queryEncoded(words)))
        }
    }

    public static let sites: [Site] = [
        Site(id: "session", name: "The Session",
             home: "https://thesession.org/tunes/search",
             search: "https://thesession.org/tunes/search?q={q}"),
        Site(id: "abcnotation", name: "abc tune search",
             home: "https://abcnotation.com/search",
             search: "https://abcnotation.com/searchTunes?q={q}&f=c&o=a"),
        Site(id: "tunearch", name: "Tunearch",
             home: "https://tunearch.org/wiki/Special:Search",
             search: "https://tunearch.org/wiki/Special:Search?search={q}"),
        Site(id: "gatherer", name: "Nigel Gatherer",
             home: "https://nigelgatherer.com/tunes/abc.html",
             search: "https://duckduckgo.com/?q=site%3Anigelgatherer.com+{q}"),
        Site(id: "norbeck", name: "Henrik Norbeck",
             home: "https://norbeck.nu/abc/",
             search: "https://duckduckgo.com/?q=site%3Anorbeck.nu+{q}"),
        Site(id: "web", name: "The whole web",
             home: "https://duckduckgo.com/",
             search: "https://duckduckgo.com/?q={q}+abc+notation"),
    ]

    /// The site used when none has been chosen, or a stored choice no longer
    /// exists.
    public static func site(id: String) -> Site {
        sites.first { $0.id == id } ?? sites[0]
    }

    /// Kept for anything still listing places to start.
    public static var suggestions: [(name: String, url: String)] {
        sites.map { ($0.name, $0.home) }
    }

    /// What was typed into the bar.
    public enum Typed: Equatable, Sendable {
        case blank
        case address(URL)
        case words(String)
    }

    /// An address if it looks like one, otherwise words to search for.
    ///
    /// An address has a scheme, or no spaces and a host ending in a dot and
    /// at least two letters ("nigelgatherer.com/tunes"). Anything with a
    /// space is words, so "St. Anne's Reel" is a search and not a host.
    public static func interpret(_ typed: String) -> Typed {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .blank }
        if text.contains("://") {
            if let url = URL(string: text), url.host != nil { return .address(url) }
            return .words(text)
        }
        guard !text.contains(where: { $0.isWhitespace }) else { return .words(text) }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let last = labels.last, last.count >= 2,
              last.allSatisfy({ $0.isASCII && $0.isLetter }),
              let url = URL(string: "https://" + text) else { return .words(text) }
        return .address(url)
    }

    /// Where Go goes: the address typed, a search of the chosen site, or the
    /// site's own search page when the bar is empty.
    public static func destination(for typed: String, site: Site) -> URL? {
        switch interpret(typed) {
        case .blank: return URL(string: site.home)
        case .address(let url): return url
        case .words(let words): return site.searchURL(for: words)
        }
    }

    /// Words for a query string: spaces as `+`, everything else that is not
    /// plain letters, digits or `-._~` percent-encoded.
    public static func queryEncoded(_ words: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        allowed.insert(" ")
        let collapsed = words.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let encoded = collapsed.addingPercentEncoding(withAllowedCharacters: allowed) ?? collapsed
        return encoded.replacingOccurrences(of: " ", with: "+")
    }

    /// What the address bar was given, as a URL. Bare hostnames get https://,
    /// because nobody types a scheme.
    public static func address(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        return URL(string: text)
    }

    // FONN-WEBSEARCH-2
    /// A link straight to an `.abc` file, as Nigel Gatherer's tune lists are.
    ///
    /// A web view shows such a file as text at best, and at worst (when the
    /// server calls it a download) does nothing at all, which is how tapping a
    /// tune on his site looked broken. So these are fetched and read directly.
    public static func isABCFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "abc"
    }

    /// Decode a fetched file. UTF-8 first; many older collections are Latin-1.
    public static func text(fromFile data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Turn a fetched `.abc` file into sources for the review screen, named
    /// by its first `T:` line, or by the file name when it has none.
    public static func sources(fromFile text: String, url: URL) -> [ABCImportPlan.Source] {
        let tidied = tidy(text)
        guard !tidied.isEmpty else { return [] }
        let firstTitle = tidied.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("T:") }
            .map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(2))
                    .trimmingCharacters(in: .whitespaces) }
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = (firstTitle?.isEmpty == false ? firstTitle! : fileName)
        return [ABCImportPlan.Source(name: name.isEmpty ? "Web file" : name, text: tidied)]
    }
}
