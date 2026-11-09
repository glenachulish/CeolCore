import SwiftUI

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

    public init(drone: Drone?, onClose: (() -> Void)? = nil) {
        self.drone = drone
        self.onClose = onClose
    }

    public static let defaultBacking = "acoustic_guitar_nylon"

    public static let levels: [(label: String, velocity: Int)] = [
        ("Quiet", 40), ("Soft", 65), ("Medium", 85), ("Strong", 110),
    ]

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
                    Picker("Volume", selection: $accompLevel) {
                        ForEach(Self.levels, id: \.velocity) { level in
                            Text(level.label).tag(level.velocity)
                        }
                    }
                    .pickerStyle(.segmented)
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

    /// For the button that opens the panel: "Irish Flute · Guitar · Drone D",
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
            HStack {
                Text("Volume")
                Slider(value: $drone.volume, in: 0...1)
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
