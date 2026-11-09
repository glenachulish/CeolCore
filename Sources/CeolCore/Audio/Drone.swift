import Foundation
import AVFoundation
import Combine

// FONN-DRONE-1
/// A drone under the music, as a piper or a shruti box would give it — on the
/// phone, the iPad and the Mac alike.
///
/// It drones on the tune's home note, read from the K: field (D for D major,
/// D mixolydian or D dorian; E for E minor; A for A dorian), following any
/// transposition. You can choose another sound or another note, and the choice
/// is kept on the tune (or set) itself, so it syncs to your other devices
/// (FONN-DRONE-2).
///
/// Like the metronome, it has a switch (`armed`) and a rule for when it sounds:
/// with the tune's playback in the ordinary view, on its own in Sheet music
/// mode (`standalone`). It plays through its own audio engine, inside the app,
/// so it carries on with the screen locked.
///
/// The sounds are real recordings looped seamlessly, retuned by varispeed to
/// the note wanted (never more than six semitones from where they were
/// recorded). See Web/drones/CREDITS.txt for where each came from.
@MainActor
public final class Drone: ObservableObject {

    // MARK: Sounds

    public enum Sound: String, CaseIterable, Identifiable, Sendable {
        case smallPipes
        case reed

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .smallPipes: return "Small pipes"
            case .reed:       return "Reed"
            }
        }

        /// The pipes of this drone: file, the pitch class it was recorded on,
        /// its true pitch in Hz (for tuning) and the equal-tempered pitch it
        /// should be, and how loud it sits in the mix.
        fileprivate var layers: [Layer] {
            switch self {
            case .smallPipes:
                // A bagpipe in G with two drones, an octave apart.
                return [Layer(file: "smallpipes-low-G2", pitchClass: 7,
                              measuredHz: 97.95, equalHz: 98.00, gain: 0.85),
                        Layer(file: "smallpipes-high-G3", pitchClass: 7,
                              measuredHz: 196.33, equalHz: 196.00, gain: 0.6)]
            case .reed:
                // Root, fifth and octave in one, as a shruti box gives them.
                return [Layer(file: "reed-A2", pitchClass: 9,
                              measuredHz: 110, equalHz: 110, gain: 0.8)]
            }
        }
    }

    fileprivate struct Layer {
        let file: String
        let pitchClass: Int
        let measuredHz: Double
        let equalHz: Double
        let gain: Float
    }

    // MARK: State

    /// The switch.
    @Published public var armed = false { didSet { if armed != oldValue { sync() } } }
    /// The tune is playing — the drone sounds with it.
    @Published public var musicPlaying = false { didSet { if musicPlaying != oldValue { sync() } } }
    /// Sheet music mode: no playback there, so it sounds whenever it is on.
    @Published public var standalone = false { didSet { if standalone != oldValue { sync() } } }

    @Published public var sound: Sound {
        didSet {
            guard sound != oldValue else { return }
            saveChoice()
            if isRunning { stop(); sync() }
        }
    }
    /// The note, as a pitch class (0 = C … 11 = B).
    @Published public var note: Int {
        didSet {
            guard note != oldValue else { return }
            saveChoice()
            retune()
        }
    }
    /// Half the volume of the music by default: a drone sits under a tune.
    @Published public var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
            mixer.outputVolume = Float(volume)
        }
    }

    /// The tune's own home note, from its key — nil when the key gives none.
    @Published public private(set) var tuneNote: Int?
    /// Whether the note is still the tune's own.
    public var followsTune: Bool { tuneNote == nil || note == tuneNote }

    @Published public private(set) var isRunning = false

    /// The phone hands in a way to make its audio session ready, as it does
    /// for the metronome. Nothing on a Mac.
    public var prepareSession: (() -> Void)?

    // MARK: Engine

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var players: [(player: AVAudioPlayerNode, speed: AVAudioUnitVarispeed, layer: Layer)] = []
    /// Where a changed sound or note goes: onto the tune or set itself, so it
    /// syncs (FONN-DRONE-2). Nil while nothing is open.
    private var keep: ((String, Int) -> Void)?
    /// True while a tune's own settings are being applied, so applying them
    /// isn't mistaken for you choosing them.
    private var applying = false

    private static let soundKey = "fonn.drone.sound"
    private static let volumeKey = "fonn.drone.volume"

    public init() {
        sound = Sound(rawValue: UserDefaults.standard.string(forKey: Self.soundKey) ?? "") ?? .smallPipes
        note = 2   // D, until a tune says otherwise
        volume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 0.5
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        mixer.outputVolume = Float(volume)
    }

    // MARK: The tune

    /// Called with each tune (or set) shown: its key, any transposition, what
    /// was chosen for it before (`savedSound` "" and `savedNote` -1 for
    /// nothing), and where to keep a new choice — the tune's or set's own
    /// `droneSound` / `droneNote`, which sync between your devices.
    public func setTune(abc: String, transpose: Int = 0,
                        savedSound: String, savedNote: Int,
                        keep: @escaping (String, Int) -> Void) {
        applying = true
        defer { applying = false }
        self.keep = keep
        let home = Self.homeNote(fromABC: abc).map { (($0 + transpose) % 12 + 12) % 12 }
        tuneNote = home
        if let s = Sound(rawValue: savedSound) { sound = s }
        if (0..<12).contains(savedNote) {
            note = savedNote
        } else if let home {
            note = home
        }
    }

    /// Back to the tune's own note.
    public func matchTheTune() {
        if let tuneNote { note = tuneNote }
    }

    private func saveChoice() {
        guard !applying else { return }
        UserDefaults.standard.set(sound.rawValue, forKey: Self.soundKey)
        // The note is kept only when it isn't simply the tune's own, so a
        // change of key later is followed.
        keep?(sound.rawValue, note == tuneNote ? -1 : note)
    }

    /// The home note of an ABC tune, from its first K: line: the tonic,
    /// whatever the mode. "K:Ador" → A, "K:Em" → E, "K:Bb" → B♭, "K:HP" (pipe
    /// notation) → A. Nil for "K:none" or no key.
    public static func homeNote(fromABC abc: String) -> Int? {
        guard let line = abc.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("K:") }) else { return nil }
        let key = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let lower = key.lowercased()
        if lower.hasPrefix("hp") { return 9 }
        guard let first = key.first?.uppercased(), let base = ["C": 0, "D": 2, "E": 4, "F": 5,
                                                              "G": 7, "A": 9, "B": 11][first]
        else { return nil }
        var pc = base
        let rest = key.dropFirst()
        if rest.hasPrefix("#") { pc += 1 }
        if rest.hasPrefix("b") { pc -= 1 }
        return (pc + 12) % 12
    }

    public static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    // MARK: Running

    public func toggle() { armed.toggle() }

    private var shouldSound: Bool { armed && (standalone || musicPlaying) }

    private func sync() {
        if shouldSound {
            if !isRunning { start() }
        } else if isRunning {
            stop()
        }
    }

    private func start() {
        prepareSession?()
        players.forEach { engine.detach($0.player); engine.detach($0.speed) }
        players = []
        for layer in sound.layers {
            guard let url = CeolResources.drone(layer.file),
                  let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { continue }
            let player = AVAudioPlayerNode()
            let speed = AVAudioUnitVarispeed()
            engine.attach(player)
            engine.attach(speed)
            engine.connect(player, to: speed, format: buffer.format)
            engine.connect(speed, to: mixer, format: buffer.format)
            player.volume = layer.gain
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            players.append((player, speed, layer))
        }
        retune()
        do {
            if !engine.isRunning { try engine.start() }
            // A swell rather than a switch, as drones come in.
            mixer.outputVolume = 0
            players.forEach { $0.player.play() }
            isRunning = true
            fade(to: Float(volume), over: 0.6)
        } catch {
            isRunning = false
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        fade(to: 0, over: 0.3) { [weak self] in
            guard let self, !self.isRunning else { return }
            self.players.forEach { $0.player.stop() }
            self.engine.pause()
            self.mixer.outputVolume = Float(self.volume)
        }
    }

    /// Each pipe to the note, moving it the short way round (never more than
    /// six semitones), and corrected for how it was tuned when recorded.
    private func retune() {
        for entry in players {
            var shift = ((note - entry.layer.pitchClass) % 12 + 12) % 12
            if shift > 6 { shift -= 12 }
            let correction = entry.layer.equalHz / entry.layer.measuredHz
            entry.speed.rate = Float(pow(2, Double(shift) / 12) * correction)
        }
    }

    private var fadeTimer: Timer?
    private func fade(to target: Float, over seconds: Double, then: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        let start = mixer.outputVolume
        let steps = max(1, Int(seconds / 0.03))
        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                step += 1
                let f = Float(step) / Float(steps)
                self.mixer.outputVolume = start + (target - start) * f
                if step >= steps { timer.invalidate(); then?() }
            }
        }
    }
}

extension CeolResources {
    /// A bundled drone loop, e.g. "smallpipes-low-G2".
    public static func drone(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Web/drones")
    }
}
