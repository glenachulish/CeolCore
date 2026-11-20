import SwiftUI
import Foundation

// FONN-SOUNDPANEL-1
/// Everything about how the music sounds, in one panel with three sections,
/// the same on iOS and the Mac: what plays the **melody**, what plays the
/// **backing** (and how), and the **drone**. Each is independent of the others.
///
/// It replaces a menu of six pickers in a row, where it wasn't clear which
/// choice belonged to which sound, and the separate "Keep these chords".
/// Chords Fonn suggests for a tune with none simply play (and show grey on
/// the music); turn them off here, or turn the backing off altogether.
///
/// The settings are the same `@AppStorage` keys the music pages read.
public struct SoundPanel: View {
    @AppStorage("ceol.voice") private var voice = "flute"
    @AppStorage("ceol.chords") private var chordsOn = true
    @AppStorage("ceol.accomp") private var accompaniment = ""
    @AppStorage("ceol.accompVol") private var accompLevel = 85
    @AppStorage(AccompanimentStyle.key) private var accompStyle = AccompanimentStyle.picked.rawValue
    @AppStorage(AutoChords.key) private var autoChords = true
    @AppStorage(StrumPattern.key) private var strumPattern = StrumPattern.folk.rawValue

    let drone: Drone?
    var onClose: (() -> Void)?
    /// FONN-VOLUME-1: where the backing slider is while it's being dragged;
    /// the level itself is set when you let go, as each change rebuilds the
    /// backing.
    @State private var backingSlider: Double?
    @State private var backingDragging = false

    public init(drone: Drone?, onClose: (() -> Void)? = nil) {
        self.drone = drone
        self.onClose = onClose
    }

    public static let defaultBacking = "acoustic_guitar_nylon"

    /// FONN-QUIETER-1: Quiet and Soft lowered (were 40 and 65): Callum
    /// found them not quiet enough under the melody. MIDI velocities; the
    /// page scales them again for chords and bass (voices.js).
    public static let levels: [(label: String, velocity: Int)] = [
        ("Quiet", 20), ("Soft", 40), ("Medium", 85), ("Strong", 110),
    ]

    /// FONN-QUIETER-1: someone who had picked Quiet (40) or Soft (65) keeps
    /// the same choice at its new, quieter level, rather than being left on
    /// a number the picker no longer shows. Once per device; called from
    /// each app's init.
    public static func updateLevelsOnce() {
        let defaults = UserDefaults.standard
        let doneKey = "ceol.accompVol.quieter1"
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard defaults.object(forKey: "ceol.accompVol") != nil else { return }
        switch defaults.integer(forKey: "ceol.accompVol") {
        case 40: defaults.set(20, forKey: "ceol.accompVol")
        case 65: defaults.set(40, forKey: "ceol.accompVol")
        default: break
        }
    }

    /// Off, or an instrument. "Off" turns the chords off rather than choosing
    /// a silent instrument, so the instrument is still there when they're on.
    private var backing: Binding<String> {
        Binding(
            get: {
                guard chordsOn else { return "off" }
                return accompaniment.isEmpty ? Self.defaultBacking : accompaniment
            },
            set: { new in
                if new == "off" {
                    chordsOn = false
                } else {
                    chordsOn = true
                    accompaniment = new
                }
            })
    }

    public var body: some View {
        Form {
            Section {
                Picker("Instrument", selection: $voice) {
                    ForEach(CeolVoice.all) { v in
                        Text(v.label).tag(v.id)
                    }
                }
            } header: {
                Text("Melody")
            }

            Section {
                Picker("Instrument", selection: backing) {
                    Text("Off").tag("off")
                    ForEach(CeolVoice.accompaniment) { v in
                        Text(v.label).tag(v.id)
                    }
                }
                if chordsOn {
                    Picker("Style", selection: $accompStyle) {
                        ForEach(AccompanimentStyle.allCases) { style in
                            Text(style.shortLabel).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    // FONN-STRUM-4: only meaningful when strumming.
                    if accompStyle == AccompanimentStyle.strummed.rawValue {
                        Picker("Strum", selection: $strumPattern) {
                            ForEach(StrumPattern.allCases) { pattern in
                                Text(pattern.label).tag(pattern.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    // FONN-VOLUME-1: a slider, from far quieter than Quiet
                    // up to a little louder than Strong.
                    LoudnessSlider(value: Binding(
                        get: { backingSlider ?? Loudness.backingSlider(accompLevel) },
                        set: { v in
                            backingSlider = v
                            if !backingDragging {
                                accompLevel = Loudness.backingVelocity(v)
                                backingSlider = nil
                            }
                        }),
                        label: "Volume",
                        onEditingChanged: { editing in
                            backingDragging = editing
                            if !editing, let v = backingSlider {
                                accompLevel = Loudness.backingVelocity(v)
                                backingSlider = nil
                            }
                        })
                    Toggle("Suggest chords when a tune has none", isOn: $autoChords)
                }
            } header: {
                Text("Backing")
            } footer: {
                Text(backingFooter)
            }

            if let drone {
                Section {
                    DroneControls(drone: drone)
                } header: {
                    Text("Drone")
                } footer: {
                    Text("On the tune's home note unless you choose another. Sounds with the tune, or on its own in Sheet music mode.")
                }
            }

            // FONN-HOWTO-1: nothing shows until there is a video.
            if HowToVideos.shared.url(for: .sound) != nil {
                Section { HowToLink(.sound) }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 380, minHeight: 420)
    }

    private var backingFooter: String {
        guard chordsOn else { return "No backing. Chords on the music are still shown." }
        var text = "Plays the chords written above the music. Chords Fonn suggests are shown in grey."
        if accompStyle == AccompanimentStyle.strummed.rawValue {
            let pattern = StrumPattern(rawValue: strumPattern) ?? .folk
            text = pattern.label + ": " + pattern.detail + " " + text
        }
        return text
    }

    /// For the button that opens the panel: "Wooden Flute · Guitar · Drone D",
    /// so you can see all three at a glance.
    public static func summary(voice: String, chordsOn: Bool, accompaniment: String,
                               drone: Drone?) -> String {
        var parts = [CeolVoice.label(for: voice)]
        if chordsOn {
            parts.append(CeolVoice.label(for: accompaniment.isEmpty ? defaultBacking : accompaniment))
        }
        if let drone, drone.armed {
            parts.append("Drone \(Drone.noteNames[drone.note])")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - FONN-VOLUME-1

/// The volume sliders' scale. Even steps in decibels rather than in raw
/// level, so the quiet end has room to move: on a plain level slider the
/// bottom quarter was all "too loud or silent". The top is where the loudest
/// was before (the drone) or a little above Strong (the backing).
public enum Loudness {
    /// The backing, as a MIDI velocity (what the music pages read): 120 at
    /// the top, falling 32 dB to 3 at the bottom. Quiet (20) sits about
    /// halfway, Strong (110) near the top.
    public static func backingVelocity(_ slider: Double) -> Int {
        let s = min(1, max(0, slider))
        return max(2, Int((120 * pow(10, (s - 1) * 32 / 20)).rounded()))
    }
    public static func backingSlider(_ velocity: Int) -> Double {
        let v = Double(max(2, min(120, velocity)))
        return min(1, max(0, 1 + 20 * log10(v / 120) / 32))
    }
    /// The drone, as a gain (`Drone.volume`): 1 at the top, as before,
    /// falling 36 dB at the bottom. The old default, 0.5, is about 5/6 up.
    public static func droneGain(_ slider: Double) -> Double {
        let s = min(1, max(0, slider))
        return pow(10, (s - 1) * 36 / 20)
    }
    public static func droneSlider(_ gain: Double) -> Double {
        guard gain > 0 else { return 0 }
        return min(1, max(0, 1 + 20 * log10(gain) / 36))
    }
}

/// A volume slider with a quiet speaker at one end and a loud one at the other.
struct LoudnessSlider: View {
    @Binding var value: Double
    let label: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
            Slider(value: $value, in: 0...1, onEditingChanged: onEditingChanged)
                .accessibilityLabel(label)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// The drone's choices — Off or a sound, the note, the volume — for the Sound
/// panel and the drone's own panel alike.
public struct DroneControls: View {
    @ObservedObject var drone: Drone

    public init(drone: Drone) { self.drone = drone }

    private var choice: Binding<String> {
        Binding(
            get: { drone.armed ? drone.sound.rawValue : "off" },
            set: { new in
                if let sound = Drone.Sound(rawValue: new) {
                    drone.sound = sound
                    drone.armed = true
                } else {
                    drone.armed = false
                }
            })
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    public var body: some View {
        Picker("Drone", selection: choice) {
            Text("Off").tag("off")
            ForEach(Drone.Sound.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        if drone.armed {
            VStack(alignment: .leading, spacing: 6) {
                Text(noteCaption).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(0..<12, id: \.self) { pc in
                        Button {
                            drone.note = pc
                        } label: {
                            Text(Drone.noteNames[pc])
                                .font(.callout.weight(pc == drone.note ? .bold : .regular))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(pc == drone.note ? Color.accentColor.opacity(0.2)
                                                             : Color.secondary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 7))
                                .overlay(alignment: .topTrailing) {
                                    if pc == drone.tuneNote {
                                        Circle().fill(Color.accentColor)
                                            .frame(width: 5, height: 5).padding(4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // FONN-VOLUME-1: the same decibel scale as the backing's, so it
            // goes much quieter than it did; the top is unchanged.
            LoudnessSlider(value: Binding(
                get: { Loudness.droneSlider(drone.volume) },
                set: { drone.volume = Loudness.droneGain($0) }),
                label: "Volume")
            // FONN-CHORDDRONE-1
            if drone.canFollowChords {
                Toggle(isOn: $drone.followChords) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Follow the chords")
                        Text("The drone moves to each chord's note as the tune plays, using the chords written in the tune or the ones Fonn suggests.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var noteCaption: String {
        guard let home = drone.tuneNote else { return "Note" }
        return drone.followsTune
            ? "Note — \(Drone.noteNames[home]), from the tune's key"
            : "Note — the tune's own is \(Drone.noteNames[home]) (dot)"
    }
}
