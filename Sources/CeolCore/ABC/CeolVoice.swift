import Foundation

/// The melody instruments, mirroring `CEOL_VOICES` in voices.js.
///
/// The list lives in two places because the two sides need it for different
/// reasons: the page builds the synth from it, and the app now draws the menu
/// from it. Four of them are in the bundle and play with no signal; the rest
/// are fetched once and cached (Settings → sounds).
public struct CeolVoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    /// Bundled, so it works at a session with no reception.
    public let offline: Bool
    /// General MIDI program number. The same numbers `voices.js` carries — they
    /// are what `%%MIDI chordprog` takes when this instrument is used for the
    /// accompaniment rather than the melody.
    public let program: Int

    public init(id: String, label: String, offline: Bool, program: Int) {
        self.id = id
        self.label = label
        self.offline = offline
        self.program = program
    }

    public static let all: [CeolVoice] = [
        CeolVoice(id: "flute",                 label: "Irish Flute",   offline: true,  program: 73),
        CeolVoice(id: "mflute",                label: "Concert Flute", offline: true,  program: 73),
        CeolVoice(id: "whistle",               label: "Tin Whistle",   offline: true,  program: 78),
        CeolVoice(id: "violin",                label: "Fiddle",        offline: true,  program: 40),
        CeolVoice(id: "accordion",             label: "Accordion",     offline: false, program: 21),
        CeolVoice(id: "banjo",                 label: "Banjo",         offline: false, program: 105),
        CeolVoice(id: "acoustic_guitar_nylon", label: "Guitar",        offline: false, program: 24),
        CeolVoice(id: "orchestral_harp",       label: "Harp",          offline: false, program: 46),
        CeolVoice(id: "acoustic_grand_piano",  label: "Piano",         offline: false, program: 0),
    ]

    /// What can back the tune. abcjs plays the chord symbols written in the
    /// ABC; this says with what.
    ///
    /// A shorter list than the melody voices on purpose — a tin whistle
    /// strumming chords is not something anyone wants. Piano is abcjs's own
    /// default, so it is what you get when nothing has been chosen.
    public static let accompaniment: [CeolVoice] = all.filter {
        ["acoustic_guitar_nylon", "acoustic_grand_piano", "orchestral_harp",
         "accordion", "banjo"].contains($0.id)
    }

    public static func program(for id: String) -> Int? {
        all.first { $0.id == id }?.program
    }

    public static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? "Irish Flute"
    }
}
