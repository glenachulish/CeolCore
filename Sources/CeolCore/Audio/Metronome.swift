
import AVFoundation
import Foundation
#if canImport(Combine)
import Combine
#endif

/// A click track that takes its tempo from the sheet music.
///
/// Two things this has to get right, both learned the hard way:
///
/// **It must not rebuild the audio engine on every tempo change.** A slider
/// emits a value per pixel of travel; stopping and rescheduling an
/// `AVAudioPlayerNode` at that rate froze the app and then killed it. Rebuilds
/// are debounced, and the buffer is built in a format we own rather than
/// whatever the mixer happens to be running.
///
/// **Its tempo comes from the tune, not from a guess.** Only 133 of 1,571
/// tunes carry a written `Q:`, so reading that alone left almost everything at
/// a meaningless default. The sheet-music engine knows the real tempo — it has
/// to, to play the tune — so it reports it here, already adjusted for the
/// Slow/Fast setting.
@MainActor
public final class Metronome: ObservableObject {

    /// Whether the click belongs to the tune, or stands on its own.
    ///
    /// It used to be neither and then both, and the history is worth keeping:
    /// unconditional clicking sounded at you while you were reading, so it was
    /// tied to playback — and that tying silently broke the standalone
    /// metronome in Settings, which has no tune and could therefore never
    /// sound. It is not a default to be argued over; it is a choice, and both
    /// answers are right in their place.
    public enum ClickMode: String, CaseIterable, Identifiable, Sendable {
        /// Starts and stops with the music, and comes in on the beat.
        case withTheTune
        /// Sounds whenever it is switched on. What a metronome usually is.
        case onItsOwn

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .withTheTune: return "With the tune"
            case .onItsOwn:    return "On its own"
            }
        }
    }

    /// Saved the moment it changes, like the timing nudge and unlike the click
    /// rate — a fresh Metronome is built for every tune page, so a mode that
    /// waited for "Save as my default" would revert each time you opened a
    /// tune. A setting you have to make again on every tune is not a setting.
    @Published public var mode: ClickMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode == .onItsOwn && armed { warmUp() }
            sync()
        }
    }

    /// Hand the click a way to make the platform's audio path ready.
    ///
    /// On iOS that is `AudioSession.shared.refresh()`, which lives in the app
    /// because it deals with interruptions, media-services resets and the
    /// ring/silent switch — none of which exist on a Mac, and none of which
    /// belong in a shared package. So the app supplies it and this stays
    /// ignorant of it.
    public var prepareSession: (() -> Void)?

    @Published public private(set) var isRunning = false

    /// Switched on — meaning "click along with the tune".
    ///
    /// This has been round the houses. It began as "armed, but waiting for the
    /// music", which produced silence with nothing on screen to explain it. It
    /// was then made unconditional, which clicked at you while you were reading.
    /// What it is now is the thing a player actually wants: the click belongs
    /// to the playback, starting and stopping with it — and the panel says
    /// "waiting for the music" when it is on and the tune is not, which is the
    /// piece that was missing the first time.
    @Published public var armed = false {
        didSet {
            // Get the engine going the moment the click is switched on, not
            // when the music starts. Starting an AVAudioEngine is not free —
            // it is tens of milliseconds, and it was being paid at exactly the
            // wrong moment: after the tune had already begun sounding. That is
            // why the first click came in a hair behind the first note however
            // the timing nudge was set. By the time the music starts there is
            // now nothing left to do but re-phase, which is cheap.
            if armed && !oldValue { warmUp() }
            sync()
        }
    }

    /// Bring the audio path up before it is needed. Safe to call repeatedly.
    private func warmUp() {
        prepareSession?()
        engine.prepare()
        do {
            if !engine.isRunning { try engine.start() }
            lastEngineProblem = nil
        } catch {
            lastEngineProblem = error.localizedDescription
        }
    }

    /// Whether the tune is sounding. The click follows it: starting when you
    /// press play, stopping when you pause, and re-phasing so it comes in on
    /// the beat rather than wherever its own loop had got to.
    @Published public var musicPlaying = false {
        didSet {
            guard musicPlaying != oldValue else { return }
            // Whether it was ALREADY going, read before sync() changes it.
            // Testing isRunning afterwards meant that starting the click and
            // re-phasing it happened in the same breath: sync() started the
            // player, then rebuildNow() immediately stopped and restarted it,
            // which is a good way to lose the first click of the tune.
            // On its own, the click owns its own phase: a tune starting is
            // not a reason to interrupt a metronome somebody is playing to.
            guard mode == .withTheTune else { return }
            let wasRunning = isRunning
            sync()                              // starts with play, stops with pause
            if musicPlaying && wasRunning { rebuildNow() }   // come in on the beat
        }
    }

    /// Take the tempo from the music. Cleared the moment you set a tempo by
    /// hand, so your choice isn't overwritten a second later.
    @Published public var followsTune = true

    @Published public var bpm: Int = 100 {
        didSet {
            let clamped = min(300, max(30, bpm))
            if clamped != bpm { bpm = clamped; return }
            if bpm != oldValue { scheduleRebuild() }
        }
    }

    @Published public var beatsPerBar: Int = 0 {
        didSet { if beatsPerBar != oldValue { scheduleRebuild() } }
    }

    @Published public var volume: Double = Metronome.savedVolume {
        didSet { engine.mainMixerNode.outputVolume = Float(volume) }
    }

    /// How often to click against the beat. A reel at 110 with a click on every
    /// crotchet is a lot of clicking to play through; half time gives you one
    /// where there were two and lets the tune breathe. Double is for slow airs,
    /// where a bare beat leaves too long a gap to hold onto. This does NOT
    /// change the tempo — the number on screen stays what the tune is at.
    public enum ClickRate: Double, CaseIterable, Identifiable, Sendable {
        case half = 0.5
        case normal = 1
        case double = 2
        public var id: Double { rawValue }
        public var label: String {
            switch self {
            case .half: return "½"
            case .normal: return "1×"
            case .double: return "2×"
            }
        }
    }

    /// Half time to begin with. A click on every beat of a reel is relentless
    /// to play through; one in two is what most players set it to anyway, so it
    /// is where it starts rather than something to go and find.
    // Metronome.savedRate, not Self.savedRate: `Self` is covariant and cannot
    // be named in a stored property initialiser. The volume and the nudge
    // below spell it out for the same reason.
    @Published public var clickRate: ClickRate = ClickRate(rawValue: Metronome.savedRate) ?? .half {
        didSet { if clickRate != oldValue { scheduleRebuild() } }
    }

    /// What the tune says, before any manual override — shown so you can get
    /// back to it.
    @Published public private(set) var tuneBPM: Int?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Our own format. Reading `mainMixerNode.outputFormat` before the engine
    /// is running can hand back a zero-channel format, and building a buffer
    /// from that crashes.
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private var rebuildTask: Task<Void, Never>?
    private var tapTimes: [Date] = []

    /// `mode` nil means "whatever was last chosen". The standalone metronome
    /// in Settings passes `.onItsOwn` explicitly: it has no tune to follow, so
    /// it must not be at the mercy of a preference set on a tune page.
    public init(mode: ClickMode? = nil) {
        self.mode = mode ?? Metronome.savedMode
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(volume)
    }

    // MARK: - What the tune says

    /// Called by the screen showing the music, with the tempo the engine is
    /// actually playing at — so Slow 60 % gives a click 40 % slower too.
    public func tempoFromTune(bpm newBPM: Int, beatsPerBar bars: Int) {
        let clamped = min(300, max(30, newBPM))
        tuneBPM = clamped
        guard followsTune else { return }
        if bars > 0, bars != beatsPerBar { beatsPerBar = bars }
        if clamped != bpm { bpm = clamped }
    }

    /// Manual change — stop following the tune, or the next report overwrites it.
    public func setBPMByHand(_ value: Int) {
        followsTune = false
        bpm = value
    }

    public func matchTheTune() {
        followsTune = true
        if let tuneBPM { bpm = tuneBPM }
    }


    // MARK: - Remembered settings

    /// Your own defaults, kept between tunes.
    ///
    /// The click rate, the volume and the timing nudge are preferences about
    /// how you like a metronome to sound, not facts about the tune — so once
    /// they suit you they should stay.
    ///
    /// The rate and the volume wait for "Save as my default", because wanting
    /// them different on the next tune is reasonable. The nudge saves itself
    /// the moment it moves — see its declaration.
    ///
    /// Two tempos are deliberately NOT here. The tune's own tempo belongs to
    /// the music and is read from the notation every time. The speed you
    /// practise a particular tune at belongs to that tune, and lives on it as
    /// `practiceBPM`.
    private static let rateKey = "ceol.metronome.rate"
    private static let volumeKey = "ceol.metronome.volume"
    private static let nudgeKey = "ceol.metronome.nudge"
    private static let modeKey = "ceol.metronome.mode"

    public static var savedRate: Double {
        let v = UserDefaults.standard.double(forKey: rateKey)
        return v > 0 ? v : ClickRate.half.rawValue
    }
    private static var savedVolume: Double {
        let v = UserDefaults.standard.double(forKey: volumeKey)
        return v > 0 ? v : 0.7
    }
    public static var savedMode: ClickMode {
        ClickMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .withTheTune
    }
    private static var savedNudge: Double {
        UserDefaults.standard.object(forKey: nudgeKey) as? Double ?? 0.03
    }

    /// True when the current settings differ from what is stored, so the panel
    /// can offer to keep them rather than showing a button that does nothing.
    public var settingsChanged: Bool {
        clickRate.rawValue != Self.savedRate
            || abs(volume - Self.savedVolume) > 0.001
            || abs(nudge - Self.savedNudge) > 0.0001
    }

    public func saveSettings() {
        UserDefaults.standard.set(clickRate.rawValue, forKey: Self.rateKey)
        UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        UserDefaults.standard.set(nudge, forKey: Self.nudgeKey)
        objectWillChange.send()
    }

    /// Back to how it comes out of the box — half time, and the tune's tempo.
    public func resetSettings() {
        UserDefaults.standard.removeObject(forKey: Self.rateKey)
        UserDefaults.standard.removeObject(forKey: Self.volumeKey)
        clickRate = .half
        volume = 0.7
        // Assigned before the key is cleared, because nudge's didSet writes
        // itself straight back to UserDefaults. Removing the key first and
        // assigning afterwards would put 0.03 back in as a stored value —
        // harmless, since that is also the default, but it would leave the
        // store saying something this function had just tried to unsay.
        nudge = 0.03
        UserDefaults.standard.removeObject(forKey: Self.nudgeKey)
        mode = .withTheTune
        UserDefaults.standard.removeObject(forKey: Self.modeKey)
        matchTheTune()
    }

    // MARK: - Running

    public func toggle() { armed.toggle() }

    private var shouldSound: Bool {
        switch mode {
        case .withTheTune: return armed && musicPlaying
        case .onItsOwn:    return armed
        }
    }

    /// What the metronome believes about itself, in one line.
    ///
    /// A click that doesn't sound has four possible reasons and no way to tell
    /// them apart from the outside: it isn't switched on; it is on but waiting
    /// for the music; the engine refused to start; or it is running and the
    /// volume is down. Rather than guess again, it says so.
    public var stateSummary: String {
        var parts: [String] = [armed ? "on" : "off"]
        if armed && !musicPlaying && mode == .withTheTune {
            parts.append("waiting for the music")
        }
        parts.append(isRunning ? "sounding" : "silent")
        if let problem = lastEngineProblem { parts.append("engine: \(problem)") }
        parts.append("\(bpm) bpm")
        parts.append("volume \(Int(volume * 100))%")
        return parts.joined(separator: " · ")
    }

    public private(set) var lastEngineProblem: String?

    private func sync() {
        if shouldSound {
            if !isRunning { start() }
        } else if isRunning {
            stop()
        }
    }

    private func start() {
        prepareSession?()
        do {
            if !engine.isRunning { try engine.start() }
            lastEngineProblem = nil
        } catch {
            // Say so rather than failing silently — a click that never comes is
            // otherwise indistinguishable from one that is switched off.
            lastEngineProblem = error.localizedDescription
            return
        }
        guard let buffer = makeLoopBuffer() else { return }
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        player.play()
        isRunning = true
    }

    public func stop() {
        rebuildTask?.cancel()
        rebuildTask = nil
        player.stop()
        // Leave the engine running while the click is still switched on, so the
        // next start doesn't pay for bringing it up again — see `warmUp`. It is
        // only paused once the metronome itself is off.
        if !armed { engine.pause() }
        isRunning = false
    }

    /// Coalesce rebuilds. Dragging a slider produces a value per pixel; acting
    /// on each one is what brought the app down.
    private func scheduleRebuild() {
        guard isRunning else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.rebuildNow()
        }
    }

    private func rebuildNow() {
        guard isRunning, let buffer = makeLoopBuffer() else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        player.play()
    }


    /// How far ahead of the beat to put the click, in frames.
    ///
    /// The output path is late by the session's own latency plus one buffer's
    /// worth of frames — the same figures the player uses. Clamped to a quarter
    /// of a beat so a very slow tempo can't shift the click onto the previous
    /// one, and to a sane ceiling in case the session reports something odd.
    private func leadFrames(sampleRate: Double, framesPerBeat: AVAudioFrameCount) -> Int {
        // What the output path costs, asked of whichever platform this is.
        // iOS knows it as the session's latency plus one buffer; a Mac has no
        // audio session, and the equivalent figure is the output node's own
        // presentation latency. Both are a floor, which is what `nudge` is for.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var seconds = session.outputLatency + session.ioBufferDuration + nudge
        #else
        var seconds = engine.outputNode.presentationLatency + nudge
        #endif
        seconds = max(0, min(seconds, 0.25))
        let frames = Int(seconds * sampleRate)
        return min(frames, Int(Double(framesPerBeat) * 0.25))
    }

    /// A hand adjustment on top of what the system reports, in seconds.
    /// The reported figures are a floor, not the whole story — the click can
    /// still sit a hair behind on a given device, and this is the dial for it.
    ///
    /// Saved the moment it changes, unlike the click rate and the volume,
    /// which wait for "Save as my default".
    ///
    /// Those two are musical choices and it is reasonable to want them
    /// different on the next tune. This is not: it is a calibration for this
    /// phone's audio latency, and the right value is the same for every tune
    /// you will ever play. A fresh Metronome is built for each tune page, so
    /// leaving it unsaved meant it reverted to 0.03 every time and the clicks
    /// landed late again — a dial you have to set once per tune is not a
    /// calibration, it is a chore.
    @Published public var nudge: Double = Metronome.savedNudge {
        didSet {
            guard nudge != oldValue else { return }
            UserDefaults.standard.set(nudge, forKey: Self.nudgeKey)
            scheduleRebuild()
        }
    }

    // MARK: - Tap tempo

    public func tap() {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2.0 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 5 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }

        var intervals: [TimeInterval] = []
        for index in 1..<tapTimes.count {
            intervals.append(tapTimes[index].timeIntervalSince(tapTimes[index - 1]))
        }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        guard average > 0.15 else { return }
        setBPMByHand(Int((60.0 / average).rounded()))
    }

    // MARK: - The click

    private func makeLoopBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let beats = max(1, beatsPerBar)
        let framesPerBeat = AVAudioFrameCount((sampleRate * 60.0 / Double(bpm)).rounded())
        guard framesPerBeat > 64 else { return nil }

        // Half time over an odd number of beats doesn't come out even in one
        // bar — three beats gives one and a half clicks — so the loop runs to
        // two bars and the pattern joins up.
        let rate = clickRate.rawValue
        let bars = (rate < 1 && beats % 2 == 1) ? 2 : 1
        let loopBeats = beats * bars

        let total = framesPerBeat * AVAudioFrameCount(loopBeats)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = total

        let clickFrames = Int(min(Double(framesPerBeat) / rate * 0.4, sampleRate * 0.012))
        guard clickFrames > 1 else { return nil }
        for frame in 0..<Int(total) { data[frame] = 0 }

        // The click sits a touch EARLY in the loop, by the amount the engine
        // will be late putting it out. A metronome that keeps perfect time but
        // lands consistently behind the beat is worse than useless — you play
        // to it and end up dragging. The buffer loops, so shifting the pattern
        // back within it shifts the phase of every click.
        let lead = leadFrames(sampleRate: sampleRate, framesPerBeat: framesPerBeat)

        let step = 1.0 / rate           // in beats
        var at = 0.0
        while at < Double(loopBeats) - 0.000_1 {
            // Wrap round the loop rather than falling off the front of it.
            var start = Int((Double(framesPerBeat) * at).rounded()) - lead
            if start < 0 { start += Int(total) }
            guard start >= 0, start + clickFrames <= Int(total) else { at += step; continue }
            // Accented downbeat a fifth higher — reads as "one" without being
            // a different sound. Only a click that lands exactly on a bar line
            // earns it.
            let onBar = abs(at.truncatingRemainder(dividingBy: Double(beats))) < 0.000_1
            let frequency = (beatsPerBar > 0 && onBar) ? 1800.0 : 1200.0
            for frame in 0..<clickFrames {
                let t = Double(frame) / sampleRate
                let envelope = exp(-Double(frame) / (Double(clickFrames) * 0.30))
                data[start + frame] = Float(sin(2 * .pi * frequency * t) * envelope * 0.9)
            }
            at += step
        }
        return buffer
    }
}
