import Foundation
import SwiftUI

// FONN-BEATS-1

/// The metronome matched to the recording playing in the strip.
///
/// Two ways in, for two kinds of recording:
/// - **Tapping**, for anything — Apple Music, a recording of your own, a
///   link. Tap with the beat for the tempo, then tap on "one" while it plays
///   and the click lines up with the recording and stays with it through
///   loops, jumps and changes of speed.
/// - **Finding**, for a recording of your own, where Fonn can read the audio.
///   `BeatDetector` finds every beat, so the click follows a recording that
///   speeds up or slows down.
///
/// Either can be saved on the recording (`MediaItem.beatBPM`,
/// `beatOffset`), so next time the click is matched as soon as it plays.
@MainActor
public final class BeatMatch: ObservableObject {
    public enum Status: Equatable {
        case idle
        case finding
        case found
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    /// The beats the click follows, once there are any.
    @Published public private(set) var grid: BeatGrid?
    /// Follow the recording when there is a grid. On by default; off keeps
    /// the metronome's own steady click at the matched tempo.
    @Published public var following = true {
        didSet { if following != oldValue { apply() } }
    }

    /// The recording this is matching, if it is an attachment.
    public private(set) weak var item: MediaItem?
    /// The recording's file, when it is on this device — what can be read.
    public private(set) var localFile: URL?

    private weak var metronome: Metronome?
    private var clock: (@MainActor () -> Metronome.RecordingClock?)?
    private var expectedBPM: Double = 120
    /// Speed of the strip, so a tapped tempo can be kept at normal speed.
    public private(set) var speed: Double = 1

    /// Beats found, kept for the session so a second visit doesn't search
    /// again. Keyed by file name.
    private static var found: [String: BeatGrid] = [:]

    public init() {}

    /// A recording has started in the strip.
    ///
    /// - `clock`: where the recording is — nil for one Fonn can't see into.
    /// - `localFile`: its file on this device, if it can be read.
    /// - `expectedBPM`: the usual tempo for the tune, which steers the finder.
    public func attach(item: MediaItem?, localFile: URL?, metronome: Metronome,
                       clock: (@MainActor () -> Metronome.RecordingClock?)?,
                       expectedBPM: Double?, speed: Double) {
        detach()
        self.item = item
        self.localFile = localFile?.isFileURL == true ? localFile : nil
        self.metronome = metronome
        self.clock = clock
        self.expectedBPM = expectedBPM ?? Double(metronome.tuneBPM ?? 120)
        self.speed = max(0.25, speed)

        let bar = max(1, metronome.beatsPerBar)
        if let name = item?.filename, !name.isEmpty, let cached = Self.found[name] {
            grid = cached
            status = .found
        } else if let item, let bpm = item.beatBPM {
            if item.beatOffset >= 0 {
                grid = BeatGrid(bpm: Double(bpm), downbeat: item.beatOffset, beatsPerBar: bar)
            } else {
                metronome.setBPMByHand(Int((Double(bpm) * self.speed).rounded()))
            }
        }
        apply()
    }

    /// The strip has closed. The metronome keeps its tempo, but its own time.
    public func detach() {
        metronome?.follow(nil, clock: nil)
        grid = nil
        status = .idle
        item = nil
        localFile = nil
        clock = nil
    }

    /// The strip's speed changed.
    public func speedChanged(_ newSpeed: Double) {
        let old = speed
        speed = max(0.25, newSpeed)
        // Following takes the speed from the recording itself. A tempo that
        // isn't following is kept in step by hand.
        guard let metronome, !metronome.isFollowing, old > 0 else { return }
        let scaled = Double(metronome.bpm) * speed / old
        metronome.setBPMByHand(Int(scaled.rounded()))
    }

    public var canFind: Bool { localFile != nil }
    public var canFollow: Bool { clock != nil }

    /// The tempo matched, at normal speed, if there is one.
    public var matchedBPM: Int? {
        if let grid { return Int(grid.bpm.rounded()) }
        return item?.beatBPM
    }

    /// Whether what is on screen differs from what is saved on the recording.
    public var canSave: Bool {
        guard item != nil, let metronome else { return false }
        let bpm = grid.map { Int($0.bpm.rounded()) }
            ?? Int((Double(metronome.bpm) / speed).rounded())
        let offset = grid?.downbeatMoment ?? -1
        return bpm != item?.beatBPM || abs(offset - (item?.beatOffset ?? -1)) > 0.01
    }

    // MARK: - Tapping

    /// Tap with the beat: the metronome's tap tempo, at the speed it is
    /// playing.
    public func tap() {
        metronome?.tap()
        // A new tempo replaces an even grid made from the old one; found
        // beats are kept — they follow the recording better than any tap.
        if let current = grid, current.times.isEmpty { grid = nil; apply() }
    }

    /// Tap on "one", while the recording plays.
    ///
    /// With a recording Fonn can see, this pins a bar to the moment tapped:
    /// on found beats it picks the nearest beat as one; otherwise it makes an
    /// even grid at the tapped tempo from there. Elsewhere (YouTube, a
    /// recording in another app) the steady click restarts on the tap.
    public func tapOne() {
        guard let metronome else { return }
        if let clock, let now = clock(), now.playing {
            let bar = max(1, metronome.beatsPerBar)
            if let current = grid {
                grid = current.withDownbeat(near: now.seconds)
            } else {
                let normal = Double(metronome.bpm) / max(0.25, now.rate)
                grid = BeatGrid(bpm: normal, downbeat: now.seconds, beatsPerBar: bar)
            }
            if !metronome.armed { metronome.armed = true }
            following = true
            apply()
        } else {
            metronome.alignNow()
        }
    }

    // MARK: - Finding

    /// Find the beat in a recording of your own.
    public func find() {
        guard let url = localFile, let metronome, status != .finding else { return }
        status = .finding
        let bar = max(1, metronome.beatsPerBar)
        let subdivision = metronome.subdivision
        let expected = expectedBPM
        let name = item?.filename ?? ""
        Task { [weak self] in
            let result: Result<BeatGrid, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try BeatDetector.analyse(
                        url: url, beatsPerBar: bar, subdivision: subdivision,
                        expectedBPM: expected))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, self.localFile == url else { return }
            switch result {
            case .success(let found):
                if !name.isEmpty { Self.found[name] = found }
                self.grid = found
                self.status = .found
                self.following = true
                self.apply()
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Saving

    /// Keep the tempo (at normal speed) and where a bar begins on the
    /// recording, so the click is matched next time it plays.
    public func save() {
        guard let item, let metronome else { return }
        if let grid {
            item.beatBPM = Int(grid.bpm.rounded())
            item.beatOffset = grid.downbeatMoment
        } else {
            item.beatBPM = Int((Double(metronome.bpm) / speed).rounded())
            item.beatOffset = -1
        }
        objectWillChange.send()
    }

    /// Forget what is saved on the recording.
    public func forget() {
        item?.beatBPM = nil
        item?.beatOffset = -1
        if let name = item?.filename { Self.found[name] = nil }
        grid = nil
        status = .idle
        apply()
    }

    // MARK: - Internals

    private func apply() {
        guard let metronome else { return }
        if following, let grid, let clock {
            metronome.follow(grid, clock: clock)
        } else {
            metronome.follow(nil, clock: nil)
            if let grid {
                metronome.setBPMByHand(Int((grid.bpm * speed).rounded()))
            }
        }
    }
}

/// Matching the click to the recording in the strip. Opened from the
/// metronome button on the strip, on iPhone, iPad and Mac.
public struct BeatMatchPanel: View {
    @ObservedObject var match: BeatMatch
    @ObservedObject var metronome: Metronome

    public init(match: BeatMatch, metronome: Metronome) {
        self.match = match
        self.metronome = metronome
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Match the click").font(.headline)
                Spacer(minLength: 12)
                Toggle(isOn: $metronome.armed) { Text(metronome.armed ? "On" : "Off") }
                    .toggleStyle(.switch)
                    .fixedSize()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(metronome.bpm)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(tempoNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Tapping: for any recording.
            HStack(spacing: 10) {
                Button {
                    match.tap()
                } label: {
                    Text("Tap with the beat")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                Button {
                    match.tapOne()
                } label: {
                    Text("Tap on “one”")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
            }
            Text("While it plays, press Tap with the beat four or more times, steadily, where your foot taps: twice a bar in a reel or a jig. Then press Tap on “one” once, on the first beat of a bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Finding: for a recording of your own.
            if match.canFind {
                HStack(spacing: 10) {
                    Button {
                        match.find()
                    } label: {
                        Text("Find the beat for me")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(match.status == .finding)
                    if match.status == .finding {
                        ProgressView().controlSize(.small)
                    }
                }
                if case .failed(let why) = match.status {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
            }

            if match.canFollow && match.grid != nil {
                Toggle("Follow the recording", isOn: $match.following)
                Text(match.grid?.times.isEmpty == false
                     ? "Clicks on every beat found, so it keeps with the players if they speed up or slow down."
                     : "Clicks at the tapped tempo from the “one” you tapped, through loops and changes of speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if match.item != nil {
                HStack(spacing: 10) {
                    Button(match.canSave ? "Save on this recording" : "Saved on this recording") {
                        match.save()
                    }
                    .disabled(!match.canSave)
                    if match.item?.beatBPM != nil {
                        Button("Forget", role: .destructive) { match.forget() }
                    }
                }
                .controlSize(.small)
            }

            HowToLink(.metronome)   // FONN-HOWTO-1
        }
        .padding(16)
        .frame(minWidth: 300, idealWidth: 340)
    }

    private var tempoNote: String {
        var parts: [String] = []
        if metronome.isFollowing {
            parts.append("following the recording")
        } else {
            parts.append("bpm")
        }
        if let matched = match.matchedBPM, abs(match.speed - 1) > 0.01 {
            parts.append("— \(matched) at full speed")
        }
        return parts.joined(separator: " ")
    }
}

/// The metronome on the recording strip: opens `BeatMatchPanel`. Red while
/// the click is following the recording.
public struct BeatMatchButton: View {
    @ObservedObject var match: BeatMatch
    @ObservedObject var metronome: Metronome
    @State private var open = false

    public init(match: BeatMatch, metronome: Metronome) {
        self.match = match
        self.metronome = metronome
    }

    public var body: some View {
        Button {
            open = true
        } label: {
            Image(systemName: "metronome")
                .foregroundStyle(metronome.isFollowing && metronome.armed ? Color.red : Color.secondary)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Match the click to this recording")
        .accessibilityLabel("Match the metronome to this recording")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            #if os(iOS)
            ScrollView { BeatMatchPanel(match: match, metronome: metronome) }
                .presentationDetents([.medium, .large])
            #else
            BeatMatchPanel(match: match, metronome: metronome)
            #endif
        }
    }
}
