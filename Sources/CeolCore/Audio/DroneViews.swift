import SwiftUI

// FONN-DRONE-1
/// The drone's button, beside the metronome's: tap for on and off, hold (or
/// Control-click on the Mac) for the sound and the note, or open the panel.
/// On shows in the accent colour with the note beside the icon, so you can see
/// at a glance what it is droning on.
public struct DroneButton: View {
    @ObservedObject var drone: Drone
    var openPanel: () -> Void

    public init(drone: Drone, openPanel: @escaping () -> Void) {
        self.drone = drone
        self.openPanel = openPanel
    }

    public var body: some View {
        Button {
            drone.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "waveform.path")
                Text(Drone.noteNames[drone.note])
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(drone.armed ? Color.accentColor : Color.secondary)
            .frame(minWidth: 44, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(drone.armed
                            ? "Drone on, \(Drone.noteNames[drone.note]). Turn it off"
                            : "Drone off. Turn it on")
        .help("Drone on \(Drone.noteNames[drone.note]) — \(drone.sound.label)")
        .contextMenu {
            Picker("Sound", selection: $drone.sound) {
                ForEach(Drone.Sound.allCases) { Text($0.label).tag($0) }
            }
            if let home = drone.tuneNote, !drone.followsTune {
                Button("Back to the tune's \(Drone.noteNames[home])") { drone.matchTheTune() }
            }
            Divider()
            Button {
                openPanel()
            } label: {
                Label("Drone note and volume…", systemImage: "slider.horizontal.3")
            }
        }
    }
}

/// The drone on its own, for the drone button's "…": the same controls as
/// the Drone section of the Sound panel (FONN-SOUNDPANEL-1).
public struct DronePanel: View {
    @ObservedObject var drone: Drone
    var onClose: (() -> Void)?

    public init(drone: Drone, onClose: (() -> Void)? = nil) {
        self.drone = drone
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    DroneControls(drone: drone)
                } footer: {
                    Text("Sounds with the tune when it plays, or on its own in Sheet music mode. A different sound or note is kept for this tune, on all your devices.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Drone")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 300)
        .presentationDetents([.medium, .large])
    }
}

/// How the accompaniment is played (FONN-ACCOMP-2): the same three on the
/// phone and the Mac, stored under the key the pages read.
public enum AccompanimentStyle: String, CaseIterable, Identifiable, Sendable {
    case picked, strummed, classic
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .picked:   return "Picked — gentle, one note at a time"
        case .strummed: return "Strummed — light, on the off-beats"
        case .classic:  return "Boom-chick — as before"
        }
    }
    public var shortLabel: String {
        switch self {
        case .picked:   return "Picked"
        case .strummed: return "Strummed"
        case .classic:  return "Boom-chick"
        }
    }
    public static let key = "ceol.accompStyle"
}
