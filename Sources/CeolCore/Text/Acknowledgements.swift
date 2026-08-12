import Foundation

/// What Fonn is built on, and the terms it is used under.
///
/// The texts live here rather than in either app because these are obligations
/// per *binary*, not per project: MIT requires its licence text to travel with
/// the software, and CC BY requires attribution wherever the work is used. The
/// Mac shipped abcjs and the soundfonts for weeks while crediting neither,
/// purely because the screen had been written on the phone and the strings
/// were locked inside it.
///
/// One copy, two screens. If a dependency is added, it is added here and both
/// apps show it.
public enum Acknowledgements {

    public struct Item: Identifiable, Sendable {
        public let id: String
        /// What this thing does in the app, in the user's terms.
        public let heading: String
        public let credit: String
        /// The licence, said plainly.
        public let terms: String
        /// The full text, where the licence requires it to be reproduced.
        public let fullText: String?
        public let links: [Link]

        public struct Link: Identifiable, Sendable {
            public let title: String
            public let url: URL
            public var id: String { url.absoluteString }

            public init(_ title: String, _ url: String) {
                self.title = title
                // Force-unwrapped deliberately: these are literals in this
                // file, and a typo should fail the first time anyone opens the
                // screen rather than silently drop a legally required link.
                self.url = URL(string: url)!
            }
        }

        public let footnote: String

        public init(id: String, heading: String, credit: String, terms: String,
                    fullText: String? = nil, links: [Link], footnote: String) {
            self.id = id
            self.heading = heading
            self.credit = credit
            self.terms = terms
            self.fullText = fullText
            self.links = links
            self.footnote = footnote
        }
    }

    public static let intro =
        "Fonn is built on work other people gave away. These are the terms it's used under."

    public static let items: [Item] = [
        Item(id: "abcjs",
             heading: "Sheet music and playback",
             credit: "abcjs — Copyright © 2009–2024 Paul Rosen and Gregory Dyke",
             terms: "Used under the MIT licence.",
             fullText: mit,
             links: [.init("abcjs.net", "https://abcjs.net")],
             footnote: "abcjs engraves the notation, plays it, and follows the notes as it goes."),

        Item(id: "fluidr3",
             heading: "Instrument sounds",
             credit: "FluidR3_GM soundfont — Frank Wen",
             terms: "Used under the Creative Commons Attribution 3.0 licence. Rendered to MP3 by the MIDI.js Soundfonts project.",
             links: [.init("creativecommons.org/licenses/by/3.0",
                           "https://creativecommons.org/licenses/by/3.0/us/")],
             footnote: "The flute, whistle, fiddle and concert flute are carried in the app so they work with no signal. The rest are fetched once and kept."),

        Item(id: "thesession",
             heading: "Tunes",
             credit: "Contains information from The Session, which is made available under the Open Database License (ODbL).",
             terms: "",
             links: [.init("thesession.org", "https://thesession.org"),
                     .init("Open Database License",
                           "https://opendatacommons.org/licenses/odbl/1-0/")],
             footnote: "A traditional melody belongs to nobody. A particular setting of it — the notes somebody chose to write down — is theirs, and on The Session those are shared under the licence above."),
    ]

    /// The MIT licence. Reproduced in full because that is what MIT requires —
    /// a link to it is not enough.
    public static let mit = """
        Permission is hereby granted, free of charge, to any person obtaining a \
        copy of this software and associated documentation files (the \
        "Software"), to deal in the Software without restriction, including \
        without limitation the rights to use, copy, modify, merge, publish, \
        distribute, sublicense, and/or sell copies of the Software, and to \
        permit persons to whom the Software is furnished to do so, subject to \
        the following conditions:

        The above copyright notice and this permission notice shall be included \
        in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS \
        OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF \
        MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. \
        IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY \
        CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, \
        TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE \
        SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """
}
