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

    /// Somewhere to start. Not an endorsement of any of them — just the places
    /// a trad player is most likely to be looking.
    public static let suggestions: [(name: String, url: String)] = [
        ("The Session", "https://thesession.org/tunes"),
        ("Tunearch", "https://tunearch.org"),
        ("irishtune.info", "https://www.irishtune.info"),
        ("Nigel Gatherer", "https://www.nigelgatherer.com/tunes/tunes.html"),
    ]

    /// What the address bar was given, as a URL. Bare hostnames get https://,
    /// because nobody types a scheme.
    public static func address(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        return URL(string: text)
    }
}
