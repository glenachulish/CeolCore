import SwiftUI

// FONN-LAYOUT-1
/// "Fixing how a tune is laid out": the help behind the Edit ABC screens on
/// both platforms. What it says was measured, not assumed — see ABCLayout.
public struct ABCLayoutHelpView: View {
    public init() {}

    static let sections: [(String, String)] = [
        ("Tidy does most of it for you",
         "When Edit ABC finds a layout problem, **Tidy the layout** fixes the first four below in one go: it joins each part onto one line, and takes out old ! line breaks, blank lines and hidden characters. It never changes a note. Nothing is kept until you save, so you can look first."),
        ("1. Each line of ABC is a new stave",
         "Fonn fits the bars to the width of your screen, but it never joins two lines of ABC: every line break starts a new stave. A tune copied from a website a bar or two to a line comes out a bar or two to a stave.\n\n**Fix:** put each part on one line, from its |: to its :|. Or end a line with a backslash \\ to carry it on to the next one."),
        ("2. Old ! line breaks",
         "Older ABC, including much of the early music on thesession.org, ends lines with !. Fonn obeys each one as a forced new stave, and a ! with no space after it can swallow the notes that follow, because ! now starts an ornament such as !trill!.\n\n**Fix:** delete any ! that isn't part of a pair like !trill! or !fermata!."),
        ("3. A blank line ends the tune",
         "In ABC an empty line means the tune is finished. Anything after it is silently dropped: if the B part has gone missing, look for a blank line above it.\n\n**Fix:** delete the empty line. To leave space between parts, use a comment line starting with % instead."),
        ("4. Hidden characters",
         "Text copied from web pages and word processors can carry non-breaking spaces and zero-width spaces. You can't see them, and the music reader skips them, which can leave notes oddly spaced or a chord in the wrong place.\n\n**Fix:** Tidy, or retype the line."),
        ("5. Bar lines",
         "Every bar needs a | at its end, or the notes run together into one long bar that can't be split across lines. Repeats are |: and :|, a double bar is ||, the end is |], and first and second endings are |1 and :|2.\n\n**Fix:** check each bar adds up. In a reel with L:1/8, a bar is eight quavers: A is one, A2 two, A3 three, A/ half."),
        ("6. Bars that don't add up",
         "A bar that is too long or too short pushes the others about. The usual causes: a missing number (A instead of A2), a broken rhythm written A> B with a space, or a wrong L: line (L:1/16 makes every note half as long).\n\n**Fix:** count the bar against the M: line; a pickup at the start, and the short last bar that balances it, are fine."),
        ("7. Headings in the middle",
         "A T: line after the K: line is drawn as a title partway through the music, and a second X: line starts another tune, which Fonn doesn't show.\n\n**Fix:** use P:A and P:B to name parts. Copy a second tune into a tune of its own, then delete it here."),
        ("8. Chords in the wrong place",
         "Chord names go in double quotes just before the note they sit over: \"G\"B2 dB. Without quotes, G is a note. For easier chord editing, use the tune's ☰ ▸ Edit the chords."),
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Fixing how a tune is laid out")
                    .font(.title2.weight(.semibold))
                ForEach(Self.sections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.0).font(.headline)
                        Text(LocalizedStringKey(section.1))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

/// The layout problems in a draft, with Tidy and the help, for the bottom of
/// either Edit ABC screen. Shows only a help link while there's nothing wrong.
public struct ABCLayoutStrip: View {
    @Binding var draft: String
    @State private var showingHelp = false

    public init(draft: Binding<String>) { self._draft = draft }

    public var body: some View {
        let problems = ABCLayout.problems(in: draft)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(problems) { problem in
                VStack(alignment: .leading, spacing: 2) {
                    Label(problem.title, systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(problem.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            HStack {
                if problems.contains(where: { $0.fixable }) {
                    Button("Tidy the layout") { draft = ABCLayout.tidy(draft) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button(problems.isEmpty ? "Layout looks odd? How to fix it" : "How to fix layout") {
                    showingHelp = true
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(problems.isEmpty ? Color.clear : Color.orange.opacity(0.08))
        .sheet(isPresented: $showingHelp) {
            VStack(spacing: 0) {
                ABCLayoutHelpView()
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showingHelp = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(10)
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
        }
    }
}
