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

/// Everything about the drone, in one panel: on/off, the sound, the note (any
/// of the twelve, with the tune's own marked) and how loud.
public struct DronePanel: View {
    @ObservedObject var drone: Drone
    var onClose: (() -> Void)?

    public init(drone: Drone, onClose: (() -> Void)? = nil) {
        self.drone = drone
        self.onClose = onClose
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Toggle(isOn: $drone.armed) {
                        Text(drone.armed ? "Drone on" : "Drone off").font(.headline)
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    Spacer(minLength: 12)
                    if let onClose { Button("Close", action: onClose) }
                }

                Picker("Sound", selection: $drone.sound) {
                    ForEach(Drone.Sound.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 6) {
                    Text(noteCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(0..<12, id: \.self) { pc in
                            Button {
                                drone.note = pc
                            } label: {
                                Text(Drone.noteNames[pc])
                                    .font(.callout.weight(pc == drone.note ? .bold : .regular))
                                    .frame(maxWidth: .infinity, minHeight: 32)
                                    .background(pc == drone.note ? Color.accentColor.opacity(0.2)
                                                                 : Color.secondary.opacity(0.1),
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(alignment: .topTrailing) {
                                        if pc == drone.tuneNote {
                                            Circle().fill(Color.accentColor)
                                                .frame(width: 5, height: 5)
                                                .padding(4)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $drone.volume, in: 0...1)
                }

                Text("Sounds with the tune when it plays, or on its own in Sheet music mode. A different sound or note is kept for this tune.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(minWidth: 300, idealWidth: 340)
        .presentationDetents([.medium, .large])
    }

    private var noteCaption: String {
        guard let home = drone.tuneNote else { return "Note" }
        return drone.followsTune
            ? "Note — \(Drone.noteNames[home]), from the tune's key"
            : "Note — the tune's own is \(Drone.noteNames[home]) (dot)"
    }
}
