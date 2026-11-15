
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
            // FONN-METRO-3: the click is already going if it is on; the tune
            // starting re-phases it so the two agree on where one is.
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

    // FONN-BEAT-1
    /// The shape of the bar the click counts out.
    ///
    /// FONN-BEAT-2: "From the tune" counts the bar out from the tune's own
    /// time signature, which is what a player expects a metronome on a page
    /// of music to do — a jig gets ONE-two-three FOUR-five-six without being
    /// asked. It was, until this, one sound a beat; that is now "Main beats
    /// only", kept for a reel you don't want a click on every crotchet of.
    /// The named signatures override the tune, for practising against a
    /// different count or with no tune at all.
    ///
    /// A counted bar is a strong click on one, a plain one where each group
    /// of the bar starts, and a quiet one on what lies between — so 6/8 is
    /// ONE-two-three FOUR-five-six and 7/8 is ONE-two THREE-four
    /// FIVE-six-seven.
    ///
    /// The tempo keeps its usual meaning in each: crotchets in 2/4 to 5/4 and
    /// in 5/8 and 7/8 (which click in quavers, two to the beat), and dotted
    /// crotchets in 6/8, 9/8 and 12/8 (three quavers to the beat), which is
    /// how a jig's tempo is given. "Clicks" (½, 1×, 2×) applies only to "Main
    /// beats only"; a counted bar says for itself where its clicks fall.
    public enum Beat: String, CaseIterable, Identifiable, Sendable {
        case fromTune = "tune"
        case mainBeats = "beats"
        case two4 = "2/4"
        case three4 = "3/4"
        case four4 = "4/4"
        case five4 = "5/4"
        case five8 = "5/8"
        case six8 = "6/8"
        case seven8 = "7/8"
        case nine8 = "9/8"
        case twelve8 = "12/8"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .fromTune:  return "From the tune"
            case .mainBeats: return "Main beats only"
            default:         return rawValue
            }
        }

        /// The bar as groups of clicks. Each group starts with an accent.
        var groups: [Int] {
            switch self {
            case .fromTune, .mainBeats: return []
            case .two4:     return [1, 1]
            case .three4:   return [1, 1, 1]
            case .four4:    return [1, 1, 1, 1]
            case .five4:    return [1, 1, 1, 1, 1]
            case .five8:    return [2, 3]
            case .six8:     return [3, 3]
            case .seven8:   return [2, 2, 3]
            case .nine8:    return [3, 3, 3]
            case .twelve8:  return [3, 3, 3, 3]
            }
        }

        /// How many clicks make one beat of the tempo.
        var clicksPerBeat: Int {
            switch self {
            case .fromTune, .mainBeats, .two4, .three4, .four4, .five4: return 1
            case .five8, .seven8:                           return 2
            case .six8, .nine8, .twelve8:                   return 3
            }
        }

        /// How the bar is counted, for the settings screen.
        public var counting: String {
            switch self {
            case .fromTune: return "The bar counted out from the tune's time signature."
            case .mainBeats: return "One click a beat. Clicks and Accent apply."
            case .two4:     return "ONE two"
            case .three4:   return "ONE two three"
            case .four4:    return "ONE two three four"
            case .five4:    return "ONE two three four five"
            case .five8:    return "ONE-two THREE-four-five"
            case .six8:     return "ONE-two-three FOUR-five-six"
            case .seven8:   return "ONE-two THREE-four FIVE-six-seven"
            case .nine8:    return "ONE-two-three FOUR-five-six SEVEN-eight-nine"
            case .twelve8:  return "ONE-two-three, four times"
            }
        }
    }

    // FONN-BEAT-2
    /// The tune's time signature as written — "6/8", "C|" — or nil when no
    /// page of music has said. What "From the tune" counts from.
    @Published public private(set) var tuneMeter: String? = nil {
        didSet { if tuneMeter != oldValue { scheduleRebuild() } }
    }

    /// A bar of `meter` as groups of clicks, and how many clicks make one
    /// beat of the tempo the page reports.
    ///
    /// The page counts beats as a player does — two to a bar of 6/8, seven to
    /// a bar of 7/8 — and its tempo is in those beats. So the compound times
    /// click three to the beat, and everything else one.
    static func counted(meter: String?, beats: Int) -> (groups: [Int], clicksPerBeat: Int) {
        let plain = (groups: Array(repeating: 1, count: max(1, beats)), clicksPerBeat: 1)
        guard var text = meter?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return plain
        }
        if text == "C" { text = "4/4" }
        if text == "C|" { text = "2/2" }
        let parts = text.split(separator: "/")
        guard parts.count == 2, let top = Int(parts[0]), let bottom = Int(parts[1]),
              top > 0, top <= 24, bottom > 0 else { return plain }
        guard bottom == 8 else {
            return (Array(repeating: 1, count: top), 1)
        }
        if top % 3 == 0 {
            return (Array(repeating: 3, count: top / 3), 3)      // 6/8, 9/8, 12/8
        }
        // 5/8, 7/8 and their kin: twos, with the three at the end.
        if top < 4 { return (Array(repeating: 1, count: top), 1) }
        var groups = Array(repeating: 2, count: top / 2)
        if top % 2 == 1 { groups[groups.count - 1] = 3 }
        return (groups, 1)
    }

    /// The bar being counted now: the tune's, or the one picked.
    private var countedBar: (groups: [Int], clicksPerBeat: Int) {
        beat == .fromTune
            ? Self.counted(meter: tuneMeter, beats: beatsPerBar)
            : (beat.groups, beat.clicksPerBeat)
    }

    /// Whether the click is one sound a beat — picked, or because there is no
    /// tune and no bar length to count from (the metronome in Settings).
    private var plainBeats: Bool {
        beat == .mainBeats || (beat == .fromTune && tuneMeter == nil && beatsPerBar <= 0)
    }

    /// What is being counted, for the settings screen.
    public var countingNow: String {
        guard beat == .fromTune, let tuneMeter else {
            let text = beat.counting
            return text.hasSuffix(".") ? text : text + "."
        }
        return "The bar counted out from the tune's time signature, \(tuneMeter)."
    }

    /// The rate to show on the music's click button: its own, or 4 for a
    /// counted bar, which the page draws as a plain on and off.
    ///
    /// FONN-METRO-3: always 4, so the button is a plain on and off. It used
    /// to cycle off, ½, 1×, 2×, which made "on" a matter of counting taps.
    /// How often it clicks is in the panel, under Fine tuning.
    public var pageClickRate: Double { 4 }

    /// The click button on the music was pressed.
    public func fromPage(on: Bool, rate: Double, fallback: ClickRate = .normal) {
        armed = on
    }

    /// FONN-METRO-3: belongs to the tune now, not to the app. It was kept
    /// as a preference, so picking 7/8 for one tune left every tune after it
    /// counting seven — which is a good part of why the metronome felt
    /// unpredictable. Every tune starts on "From the tune"; a different count
    /// is kept only by "Save for this tune" (`practiceBeat`).
    @Published public var beat: Beat = .fromTune {
        didSet { if beat != oldValue { scheduleRebuild() } }
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
        // FONN-BEAT-2: the time signature rides along — see TuneMeterReport.
        if let meter = TuneMeterReport.latest {
            TuneMeterReport.latest = nil
            if meter != tuneMeter { tuneMeter = meter }
        }
        // The bar's length is the music's whatever the tempo, so it is taken
        // even when you have set a tempo of your own.
        if bars > 0, bars != beatsPerBar { beatsPerBar = bars }
        guard followsTune else { return }
        if clamped != bpm { bpm = clamped }
    }

    // MARK: - Following a recording (FONN-BEATS-1)

    /// Where a recording is: seconds from its start, the speed it is playing
    /// at, and whether it is playing.
    public struct RecordingClock: Sendable {
        public var seconds: Double
        public var rate: Double
        public var playing: Bool
        public init(seconds: Double, rate: Double, playing: Bool) {
            self.seconds = seconds
            self.rate = rate
            self.playing = playing
        }
    }

    /// Whether the click is following a recording's beat rather than keeping
    /// its own time.
    @Published public private(set) var isFollowing = false

    private var followGrid: BeatGrid?
    private var followClock: (@MainActor () -> RecordingClock?)?
    private var followTimer: Timer?
    private var followPrimed = false
    private var anchorHost: UInt64 = 0
    private var anchorTrack: Double = 0
    private var anchorRate: Double = 1
    private var scheduledUntil: Double = 0
    private lazy var followSounds: [AVAudioPCMBuffer] = makeFollowSounds()

    /// Follow a recording: click on its beats — found or tapped — wherever it
    /// is playing, at whatever speed, through A–B loops and jumps. Nil goes
    /// back to the metronome's own steady click.
    ///
    /// The beats are scheduled a little ahead, each at the moment it will be
    /// heard, worked out from where the recording says it is. Twenty times a
    /// second that is checked against where it should be; if it has moved
    /// (a seek, the loop jumping back, a change of speed) the schedule is
    /// thrown away and started again from there.
    public func follow(_ grid: BeatGrid?, clock: (@MainActor () -> RecordingClock?)?) {
        if isRunning { stop() }
        followGrid = grid
        followClock = grid == nil ? nil : clock
        isFollowing = followGrid != nil && followClock != nil
        followPrimed = false
        sync()
    }

    /// Restart the steady click with its bar beginning now — "Tap on one",
    /// for a recording Fonn can't see the position of (YouTube, another app).
    public func alignNow() {
        guard !isFollowing else { return }
        if !armed {
            armed = true
        } else if isRunning {
            rebuildNow()
        } else {
            sync()
        }
    }

    /// Three in a jig's beat, two otherwise — from the tune's time signature.
    public var subdivision: Int {
        guard let meter = tuneMeter else { return 2 }
        let parts = meter.split(separator: "/")
        guard parts.count == 2, let top = Int(parts[0]), let bottom = Int(parts[1]) else { return 2 }
        return (bottom == 8 && top % 3 == 0) ? 3 : 2
    }

    private func startFollowing() {
        guard followTimer == nil else { return }
        warmUp()
        guard engine.isRunning else { return }
        player.stop()
        player.play()
        followPrimed = false
        isRunning = true
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
        followTick()
    }

    private func followTick() {
        guard isFollowing, armed, let grid = followGrid, followSounds.count == 2 else { return }
        guard let clock = followClock?(), clock.playing, clock.rate > 0.05 else {
            // Paused: drop whatever was scheduled, so nothing clicks on.
            if followPrimed {
                player.stop()
                player.play()
                followPrimed = false
            }
            return
        }
        let now = mach_absolute_time()
        let elapsed = followPrimed ? AVAudioTime.seconds(forHostTime: now &- anchorHost) : 0
        let expected = anchorTrack + elapsed * anchorRate
        if !followPrimed || abs(expected - clock.seconds) > 0.04
            || abs(clock.rate - anchorRate) > 0.001 {
            player.stop()
            player.play()
            anchorHost = now
            anchorTrack = clock.seconds
            anchorRate = clock.rate
            scheduledUntil = clock.seconds + 0.02 * clock.rate
            followPrimed = true
            let shown = min(300, max(30, Int((grid.bpm * clock.rate).rounded())))
            if shown != bpm {
                followsTune = false
                bpm = shown
            }
        }
        let sinceAnchor = AVAudioTime.seconds(forHostTime: now &- anchorHost)
        let horizon = clock.seconds + 0.6 * clock.rate
        let lead = leadSeconds()
        for beat in grid.beats(from: scheduledUntil, to: horizon) {
            let delay = (beat.time - anchorTrack) / anchorRate - lead
            guard delay > sinceAnchor + 0.005 else { continue }   // already gone
            let host = anchorHost &+ AVAudioTime.hostTime(forSeconds: delay)
            let sound = beat.inBar == 0 ? followSounds[0] : followSounds[1]
            player.scheduleBuffer(sound, at: AVAudioTime(hostTime: host), options: [],
                                  completionHandler: nil)
        }
        scheduledUntil = max(scheduledUntil, horizon)
    }

    /// One click for one, a plainer one for the other beats — the same two
    /// sounds as the counted bar.
    private func makeFollowSounds() -> [AVAudioPCMBuffer] {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * 0.012)
        return [(1800.0, 0.9), (1200.0, 0.7)].compactMap { pair in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let data = buffer.floatChannelData?[0] else { return nil }
            buffer.frameLength = frames
            for frame in 0..<Int(frames) {
                let t = Double(frame) / rate
                let envelope = exp(-Double(frame) / (Double(frames) * 0.30))
                data[frame] = Float(sin(2 * .pi * pair.0 * t) * envelope * pair.1)
            }
            return buffer
        }
    }

    // MARK: - This tune (FONN-METRO-3)

    /// What "Save for this tune" kept: a tempo (nil: follow the music) and a
    /// beat (nil: count the tune's own time signature).
    @Published public private(set) var savedBPM: Int?
    @Published public private(set) var savedBeat: Beat?

    /// Start on a tune: its time signature, a tempo to begin with, and
    /// whatever you saved for it.
    ///
    /// The music page reports the real tempo and time signature as soon as it
    /// has drawn the tune, and that report wins. This is for the moments
    /// before it, and for a tune that is only a PDF or a photograph, where
    /// there is no page to report: the time signature from the notation's
    /// `M:` if there is notation, otherwise the usual one for the tune's type,
    /// and a moderate tempo for that type.
    public func loadTune(abc: String, type: String, practiceBPM: Int?, practiceBeat: String) {
        let written = Self.meter(in: abc)
        let meter = written ?? TuneTypeDefaults.meter(for: type)
        tuneMeter = meter
        beatsPerBar = meter.map { Metronome.beatsPerBar(meter: $0) } ?? 0
        tuneBPM = TuneTypeDefaults.tempo(for: type)
        followsTune = true
        bpm = tuneBPM ?? bpm
        beat = .fromTune
        savedBPM = practiceBPM
        savedBeat = practiceBeat.isEmpty ? nil : Beat(rawValue: practiceBeat)
        if let savedBPM { setBPMByHand(savedBPM) }
        if let savedBeat { beat = savedBeat }
    }

    /// Whether the tempo or the beat has been moved from the tune's.
    public var isTweaked: Bool { !followsTune || beat != .fromTune }

    /// Whether anything is saved on this tune.
    public var hasSaved: Bool { savedBPM != nil || savedBeat != nil }

    /// Whether "Save for this tune" would change anything.
    public var canSaveForTune: Bool {
        let tempo: Int? = followsTune ? nil : bpm
        let count: Beat? = beat == .fromTune ? nil : beat
        return tempo != savedBPM || count != savedBeat
    }

    /// Keep the tempo and beat showing as this tune's. Returns what to store
    /// on it: `practiceBPM` (nil while following the music, so the Slow/Fast
    /// setting still moves the click) and `practiceBeat` ("" for the tune's
    /// own count).
    @discardableResult
    public func saveForTune() -> (bpm: Int?, beat: String) {
        savedBPM = followsTune ? nil : bpm
        savedBeat = beat == .fromTune ? nil : beat
        return (savedBPM, savedBeat?.rawValue ?? "")
    }

    /// The tune's own tempo and count again. What is saved stays saved.
    public func backToTheTune() {
        beat = .fromTune
        matchTheTune()
    }

    /// Forget what was saved, and go back to the tune's own tempo and count.
    public func forgetSaved() {
        savedBPM = nil
        savedBeat = nil
        backToTheTune()
    }

    /// The tune's time signature as written in its `M:` line, or nil.
    static func meter(in abc: String) -> String? {
        guard let range = abc.range(of: #"(?m)^M:\s*(\S+)"#, options: .regularExpression) else {
            return nil
        }
        let text = abc[range].dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text.lowercased() == "none" ? nil : text
    }

    /// Beats in a bar as a player counts them, as the music page does: two in
    /// 6/8, seven in 7/8.
    static func beatsPerBar(meter: String) -> Int {
        if meter == "C" { return 4 }
        if meter == "C|" { return 2 }
        let parts = meter.split(separator: "/")
        guard parts.count == 2, let top = Int(parts[0]), let bottom = Int(parts[1]),
              top > 0, bottom > 0 else { return 4 }
        if bottom == 8 && top % 3 == 0 { return top / 3 }
        return top
    }

    /// The name the beat goes by in a picker. "From the tune" says which.
    public func label(for choice: Beat) -> String {
        guard choice == .fromTune, let tuneMeter else { return choice.label }
        return "From the tune (\(tuneMeter))"
    }

    /// One line on where the tempo comes from, for under the number.
    public var tempoSource: String {
        if !followsTune {
            return savedBPM == bpm ? "saved for this tune" : "your tempo"
        }
        return tuneBPM == nil ? "bpm" : "from the tune"
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
    private static let beatKey = "ceol.metronome.beat"

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
        UserDefaults.standard.removeObject(forKey: Self.beatKey)
    }

    // MARK: - Running

    public func toggle() { armed.toggle() }

    /// FONN-SHEETMODE-1: in Sheet music mode the click always stands on its
    /// own — there is no playback there for it to wait for — whatever `mode`
    /// says for the ordinary view. Not saved: leaving the mode puts `mode` back
    /// in charge.
    @Published public var standalone = false {
        didSet {
            guard standalone != oldValue else { return }
            if standalone && armed { warmUp() }
            sync()
        }
    }

    /// FONN-METRO-3: on means clicking. Full stop.
    ///
    /// It used to depend on `mode`: "With the tune" switched on and then
    /// waited, silently, for the play button — so the button on a PDF, or on
    /// a tune you were reading, or under a recording, seemed to do nothing.
    /// Now the switch is the switch. Pressing play still re-phases the click
    /// so it comes in on the tune's beat (see `musicPlaying`).
    private var shouldSound: Bool { armed }

    /// What the metronome believes about itself, in one line.
    ///
    /// A click that doesn't sound has four possible reasons and no way to tell
    /// them apart from the outside: it isn't switched on; it is on but waiting
    /// for the music; the engine refused to start; or it is running and the
    /// volume is down. Rather than guess again, it says so.
    public var stateSummary: String {
        var parts: [String] = [armed ? "on" : "off"]
        parts.append(isRunning ? "sounding" : "silent")
        if let problem = lastEngineProblem { parts.append("engine: \(problem)") }
        parts.append("\(bpm) bpm")
        parts.append("volume \(Int(volume * 100))%")
        return parts.joined(separator: " · ")
    }

    public private(set) var lastEngineProblem: String?

    private func sync() {
        // FONN-BEATS-1: following a recording, the click is scheduled beat by
        // beat against where the recording is, not looped.
        if isFollowing {
            if armed { startFollowing() } else if isRunning { stop() }
            return
        }
        if shouldSound {
            if !isRunning { start() }
        } else if isRunning {
            stop()
        }
    }

    private func start() {
        guard !isFollowing else { return }
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
        followTimer?.invalidate()
        followTimer = nil
        followPrimed = false
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
        guard isRunning, !isFollowing, let buffer = makeLoopBuffer() else { return }
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
    /// What the output path costs, asked of whichever platform this is.
    /// iOS knows it as the session's latency plus one buffer; a Mac has no
    /// audio session, and the equivalent figure is the output node's own
    /// presentation latency. Both are a floor, which is what `nudge` is for.
    private func leadSeconds() -> Double {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let seconds = session.outputLatency + session.ioBufferDuration + nudge
        #else
        let seconds = engine.outputNode.presentationLatency + nudge
        #endif
        return max(0, min(seconds, 0.25))
    }

    private func leadFrames(sampleRate: Double, framesPerBeat: AVAudioFrameCount) -> Int {
        let frames = Int(leadSeconds() * sampleRate)
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

    /// FONN-BEAT-1: one bar of a counted pattern, to loop.
    private func makePatternBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let (groups, clicksPerBeat) = countedBar
        let clicks = groups.reduce(0, +)
        guard clicks > 0 else { return nil }
        let framesPerClick = AVAudioFrameCount(
            (sampleRate * 60.0 / Double(bpm) / Double(clicksPerBeat)).rounded())
        guard framesPerClick > 64 else { return nil }

        let total = framesPerClick * AVAudioFrameCount(clicks)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = total
        for frame in 0..<Int(total) { data[frame] = 0 }

        let clickFrames = Int(min(Double(framesPerClick) * 0.4, sampleRate * 0.012))
        guard clickFrames > 1 else { return nil }
        // Early by what the output path costs, as the plain click is.
        let lead = leadFrames(sampleRate: sampleRate, framesPerBeat: framesPerClick)

        // Where each group starts, counted in clicks from the bar line.
        var groupStarts: Set<Int> = []
        var count = 0
        for group in groups {
            groupStarts.insert(count)
            count += group
        }

        for click in 0..<clicks {
            var start = Int(framesPerClick) * click - lead
            if start < 0 { start += Int(total) }
            guard start >= 0, start + clickFrames <= Int(total) else { continue }
            // One: high and full. The start of a group: the usual click.
            // Between: lower and quiet, so the groups are what you hear.
            let frequency: Double
            let level: Double
            if click == 0 {
                frequency = 1800; level = 0.9
            } else if groupStarts.contains(click) {
                frequency = 1200; level = 0.8
            } else {
                frequency = 900; level = 0.32
            }
            for frame in 0..<clickFrames {
                let t = Double(frame) / sampleRate
                let envelope = exp(-Double(frame) / (Double(clickFrames) * 0.30))
                data[start + frame] = Float(sin(2 * .pi * frequency * t) * envelope * level)
            }
        }
        return buffer
    }

    private func makeLoopBuffer() -> AVAudioPCMBuffer? {
        if !plainBeats { return makePatternBuffer() }
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
