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

    public init(id: String, label: String, offline: Bool) {
        self.id = id
        self.label = label
        self.offline = offline
    }

    public static let all: [CeolVoice] = [
        CeolVoice(id: "flute",                 label: "Irish Flute",   offline: true),
        CeolVoice(id: "mflute",                label: "Concert Flute", offline: true),
        CeolVoice(id: "whistle",               label: "Tin Whistle",   offline: true),
        CeolVoice(id: "violin",                label: "Fiddle",        offline: true),
        CeolVoice(id: "accordion",             label: "Accordion",     offline: false),
        CeolVoice(id: "banjo",                 label: "Banjo",         offline: false),
        CeolVoice(id: "acoustic_guitar_nylon", label: "Guitar",        offline: false),
        CeolVoice(id: "orchestral_harp",       label: "Harp",          offline: false),
        CeolVoice(id: "acoustic_grand_piano",  label: "Piano",         offline: false),
    ]

    public static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? "Irish Flute"
    }
}
