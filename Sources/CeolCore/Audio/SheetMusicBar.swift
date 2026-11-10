import SwiftUI

// FONN-SHEETMODE-1
/// The bar under the music in Sheet music mode, the same on iOS and the Mac:
/// the metronome on the left, Scroll on the right.
///
/// Everything a music stand needs and nothing it doesn't. The metronome always
/// clicks on its own here (see `Metronome.standalone`), so the switch does what
/// it says the moment you press it — there is no tune to wait for. Hold − or +
/// and the tempo keeps moving. Scroll follows the tempo; Slower and Faster
/// shift it for reading ahead or catching up — labelled in words, as the − and +
/// beside the tempo already mean something else.
///
/// On a narrow phone the two halves stack; anywhere wider they share a row.
public struct SheetMusicBar: View {
    @ObservedObject var sheet: SheetMode
    @ObservedObject var metronome: Metronome
    /// The full metronome panel, for the click's sound and spacing.
    var openMetronomeSettings: () -> Void
    /// FONN-DRONE-1: the drone, beside the metronome, and its panel.
    let drone: Drone?
    var openDroneSettings: () -> Void

    public init(sheet: SheetMode, metronome: Metronome,
                drone: Drone? = nil,
                openMetronomeSettings: @escaping () -> Void,
                openDroneSettings: @escaping () -> Void = {}) {
        self.sheet = sheet
        self.metronome = metronome
        self.drone = drone
        self.openMetronomeSettings = openMetronomeSettings
        self.openDroneSettings = openDroneSettings
    }

    public var body: some View {
        // FONN-BUTTONS-2: three stages -- one row; two rows; two rows with
        // smaller controls and tighter spacing. Everything in them is held to
        // its natural width, so a stage that does not fit is passed over
        // instead of squeezed until "110" breaks into "11" and "0" and
        // "Scroll" into "Scr" and "oll" (iPhone, 10 Nov 2026).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                click(compact: false)
                Divider().frame(height: 24)
                scroll(compact: false)
                Spacer(minLength: 0)
                zoomControls
                done
            }
            VStack(spacing: 8) {
                HStack {
                    click(compact: false)
                    Spacer(minLength: 0)
                    done
                }
                HStack {
                    scroll(compact: false)
                    Spacer(minLength: 0)
                    zoomControls
                }
            }
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    click(compact: true)
                    Spacer(minLength: 0)
                    done
                }
                HStack {
                    scroll(compact: true)
                    Spacer(minLength: 0)
                    zoomControls
                }
            }
        }
        // A music stand bar must fit whatever the phone's text size is set to.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The way out, on the bar itself: in landscape on a phone the
    /// navigation bar, where the mode was turned on, is hidden.
    private var done: some View {
        Button {
            sheet.isOn = false
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Leave sheet music mode")
    }

    /// On the Mac, buttons and ⌘+ / ⌘− / ⌘0 as well as a trackpad pinch. On
    /// the phone and iPad you pinch the music itself, so nothing is drawn.
    @ViewBuilder
    private var zoomControls: some View {
        #if os(macOS)
        HStack(spacing: 4) {
            Button { sheet.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Smaller (⌘−)")
            Button { sheet.actualSize() } label: {
                Text("\(Int((sheet.zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 40)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Actual size (⌘0)")
            Button { sheet.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: .command)
                .help("Bigger (⌘+)")
        }
        .buttonStyle(.bordered)
        #endif
    }

    // MARK: Metronome

    private func click(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 10) {
            Button {
                metronome.toggle()
            } label: {
                Image(systemName: "metronome")
                    .font(.title3)
                    .foregroundStyle(metronome.armed ? Color.red : Color.secondary)
                    .frame(width: compact ? 30 : 36, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(metronome.armed ? "Metronome on" : "Metronome off")

            Button { metronome.setBPMByHand(max(30, metronome.bpm - 1)) } label: {
                Image(systemName: "minus").frame(width: compact ? 22 : 28, height: 28)
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel("Slower tempo")

            // The tempo; press it for the rest of the metronome's settings.
            Button(action: openMetronomeSettings) {
                VStack(spacing: 0) {
                    Text("\(metronome.bpm)")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text("bpm")
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: compact ? 36 : 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(metronome.bpm) beats a minute. Metronome settings")

            Button { metronome.setBPMByHand(min(300, metronome.bpm + 1)) } label: {
                Image(systemName: "plus").frame(width: compact ? 22 : 28, height: 28)
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel("Faster tempo")

            Button { metronome.tap() } label: {
                Text("Tap").lineLimit(1).fixedSize()
            }
                .buttonStyle(.bordered)
                .controlSize(.small)

            if let drone {
                DroneButton(drone: drone, openPanel: openDroneSettings)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
    }

    // MARK: Scroll

    private func scroll(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Button {
                sheet.scrolling.toggle()
            } label: {
                Label(sheet.scrolling ? "Stop" : "Scroll",
                      systemImage: sheet.scrolling ? "stop.fill" : "arrow.down.to.line")
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: compact ? 0 : 74)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
            .tint(sheet.scrolling ? .red : .accentColor)

            // Words, not − and +: those are the tempo's, just to the left, and
            // two pairs of identical buttons doing different things is a trap.
            Button { sheet.slower() } label: { Text("Slower").lineLimit(1).fixedSize() }
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            .disabled(sheet.factor <= SheetMode.slowest)
            .accessibilityLabel("Scroll slower")

            // "In time" with the metronome; press to go back to it.
            // "In time" has a space in it: in 52 points it wrapped onto two lines.
            Button { sheet.inTime() } label: {
                Text(sheet.speedLabel).lineLimit(1).fixedSize()
            }
                .buttonStyle(.plain)
                .font(.caption.monospacedDigit())
                .foregroundStyle(sheet.factor == 1 ? Color.secondary : Color.accentColor)
                .frame(minWidth: compact ? 0 : 52)
                .accessibilityLabel("Scroll speed \(sheet.speedLabel). Back in time")

            Button { sheet.faster() } label: { Text("Faster").lineLimit(1).fixedSize() }
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            .disabled(sheet.factor >= SheetMode.fastest)
            .accessibilityLabel("Scroll faster")
        }
    }
}
