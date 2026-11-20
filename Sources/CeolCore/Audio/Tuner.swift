import Foundation
import SwiftUI
import AVFoundation
import Accelerate
// @Published / ObservableObject (Member Import Visibility in the apps).
import Combine

// FONN-MACTUNER-1: moved here from the phone app, so the Mac has the same
// tuner. Only the microphone permission and the audio session differ.

/// Listens to the microphone and reports the pitch it hears.
///
/// Uses normalised autocorrelation (the McLeod-style approach) rather than an
/// FFT peak: it tracks the *fundamental* reliably even when an instrument's
/// harmonics are louder than its root — which is exactly the case for flutes,
/// whistles, fiddles and pipes.
@MainActor
public final class PitchDetector: NSObject, ObservableObject {
    /// Detected frequency in Hz, nil when nothing clear is being played.
    @Published public private(set) var frequency: Double?
    /// How confident the detection is, 0…1.
    @Published public private(set) var clarity: Double = 0
    /// Input level 0…1, for the meter.
    @Published public private(set) var level: Float = 0
    @Published public var permissionDenied = false
    @Published public private(set) var isRunning = false

    /// Concert A, adjustable for playing with instruments at a different pitch.
    @Published public var referenceA: Double = 440

    private let engine = AVAudioEngine()
    private var sampleRate: Double = 44100
    private var buffer: [Float] = []
    private let windowSize = 4096

    /// The phone hands its audio session back to playback here.
    @MainActor public static var afterListening: (() -> Void)?

    public override init() { super.init() }

    public func start() {
        guard !isRunning else { return }
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.permissionDenied = true; return }
            self.beginListening()
        }
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        #else
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        #endif
    }

    private func beginListening() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setActive(true)
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        buffer.removeAll(keepingCapacity: true)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            guard let self, let data = buf.floatChannelData?[0] else { return }
            let frames = Int(buf.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data, count: frames))
            Task { @MainActor in self.process(samples) }
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        frequency = nil
        clarity = 0
        level = 0
        // Hand the audio session back to playback.
        Self.afterListening?()
    }

    private func process(_ samples: [Float]) {
        // Running level meter (RMS).
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        level = min(1, rms * 12)

        buffer.append(contentsOf: samples)
        guard buffer.count >= windowSize else { return }
        let window = Array(buffer.suffix(windowSize))
        buffer.removeFirst(max(0, buffer.count - windowSize))

        // Too quiet to be a note — report silence rather than guessing.
        guard rms > 0.008 else {
            frequency = nil
            clarity = 0
            return
        }

        if let (freq, conf) = Self.detectPitch(window, sampleRate: sampleRate), conf > 0.55 {
            // Light smoothing so the needle doesn't jitter.
            if let current = frequency, abs(current - freq) / freq < 0.06 {
                frequency = current * 0.7 + freq * 0.3
            } else {
                frequency = freq
            }
            clarity = conf
        } else {
            clarity = 0
        }
    }

    /// Normalised autocorrelation. Returns (frequency, confidence).
    nonisolated static func detectPitch(_ samples: [Float], sampleRate: Double) -> (Double, Double)? {
        let n = samples.count
        // Search 70 Hz…1400 Hz, covering low D whistle to high fiddle notes.
        let minLag = max(2, Int(sampleRate / 1400))
        let maxLag = min(n - 1, Int(sampleRate / 70))
        guard maxLag > minLag else { return nil }

        // Remove any DC offset first.
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(n))
        var centred = samples
        var negMean = -mean
        vDSP_vsadd(samples, 1, &negMean, &centred, 1, vDSP_Length(n))

        var bestLag = -1
        var bestValue = 0.0
        var previous = 0.0
        var rising = false

        for lag in minLag...maxLag {
            var correlation: Float = 0
            var energyA: Float = 0
            var energyB: Float = 0
            let count = vDSP_Length(n - lag)
            centred.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                vDSP_dotpr(base, 1, base + lag, 1, &correlation, count)
                vDSP_svesq(base, 1, &energyA, count)
                vDSP_svesq(base + lag, 1, &energyB, count)
            }
            let denominator = sqrt(Double(energyA) * Double(energyB))
            let value = denominator > 0 ? Double(correlation) / denominator : 0

            // Take the FIRST strong peak, not the highest — the highest often
            // lands on a multiple of the true period (an octave too low).
            if value > previous { rising = true }
            else if rising && previous > 0.55 && previous > bestValue {
                bestValue = previous
                bestLag = lag - 1
                break
            } else { rising = false }
            previous = value
        }

        guard bestLag > 0 else { return nil }

        // Parabolic interpolation around the peak for sub-sample accuracy.
        func normalised(at lag: Int) -> Double {
            guard lag > 0 && lag < n else { return 0 }
            var correlation: Float = 0, energyA: Float = 0, energyB: Float = 0
            let count = vDSP_Length(n - lag)
            centred.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                vDSP_dotpr(base, 1, base + lag, 1, &correlation, count)
                vDSP_svesq(base, 1, &energyA, count)
                vDSP_svesq(base + lag, 1, &energyB, count)
            }
            let denominator = sqrt(Double(energyA) * Double(energyB))
            return denominator > 0 ? Double(correlation) / denominator : 0
        }

        let y0 = normalised(at: bestLag - 1)
        let y1 = bestValue
        let y2 = normalised(at: bestLag + 1)
        let denom = 2 * (2 * y1 - y0 - y2)
        let shift = denom != 0 ? (y2 - y0) / denom : 0
        let refinedLag = Double(bestLag) + shift

        guard refinedLag > 0 else { return nil }
        return (sampleRate / refinedLag, y1)
    }

    // MARK: - Note naming

    public static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"]

    public struct Reading {
        public let noteName: String
        public let octave: Int
        public let cents: Double        // −50…+50 from the nearest note
        public let targetFrequency: Double
    }

    /// Nearest note and how far off it is, in cents.
    public func reading(for freq: Double) -> Reading {
        let semitonesFromA4 = 12 * log2(freq / referenceA)
        let nearest = round(semitonesFromA4)
        let cents = (semitonesFromA4 - nearest) * 100
        let target = referenceA * pow(2, nearest / 12)

        // A4 is MIDI 69.
        let midi = Int(nearest) + 69
        let name = Self.noteNames[((midi % 12) + 12) % 12]
        let octave = midi / 12 - 1
        return Reading(noteName: name, octave: octave, cents: cents, targetFrequency: target)
    }
}

// MARK: - The tuner screen


/// Chromatic tuner: play a note and it shows which note you're on and how far
/// sharp or flat, with an adjustable concert-A reference for sessions that
/// don't sit at 440.
public struct TunerView: View {
    @StateObject private var detector = PitchDetector()
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ceol.referenceA") private var referenceA: Double = 440

    public init() {}

    private var reading: PitchDetector.Reading? {
        guard let freq = detector.frequency else { return nil }
        return detector.reading(for: freq)
    }

    /// Green when within 5 cents, amber within 15, otherwise red.
    private var tuningColour: Color {
        guard let cents = reading?.cents else { return .secondary }
        let off = abs(cents)
        if off < 5 { return .green }
        if off < 15 { return .orange }
        return .red
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 8)

                // Note name
                ZStack {
                    if let reading {
                        VStack(spacing: 2) {
                            Text(reading.noteName)
                                .font(.system(size: 84, weight: .semibold, design: .rounded))
                                .foregroundStyle(tuningColour)
                            Text("octave \(reading.octave)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: detector.isRunning ? "ear" : "mic.slash")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text(detector.isRunning ? "Play a note…" : "Tuner is off")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 130)

                // Cents dial
                CentsDial(cents: reading?.cents, colour: tuningColour)
                    .frame(height: 92)
                    .padding(.horizontal)

                // Readouts
                HStack(spacing: 24) {
                    readout("Detected",
                            detector.frequency.map { String(format: "%.1f Hz", $0) } ?? "—")
                    readout("Target",
                            reading.map { String(format: "%.1f Hz", $0.targetFrequency) } ?? "—")
                    readout("Off by",
                            reading.map { String(format: "%+.0f¢", $0.cents) } ?? "—")
                }
                .padding(.top, 4)

                // Level meter
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(.tint)
                            .frame(width: geo.size.width * CGFloat(detector.level))
                            .animation(.easeOut(duration: 0.1), value: detector.level)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 40)

                if detector.permissionDenied {
                    Text(Self.micOff)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                Spacer()

                // Reference pitch
                VStack(spacing: 6) {
                    Text("Concert A = \(Int(referenceA)) Hz")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button {
                            referenceA = max(415, referenceA - 1)
                            detector.referenceA = referenceA
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        Slider(value: $referenceA, in: 415...455, step: 1)
                            .onChange(of: referenceA) { _, value in detector.referenceA = value }
                        Button {
                            referenceA = min(455, referenceA + 1)
                            detector.referenceA = referenceA
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                    }
                    .padding(.horizontal, 40)
                    if referenceA != 440 {
                        Button("Reset to 440") {
                            referenceA = 440
                            detector.referenceA = 440
                        }
                        .font(.caption)
                    }
                }
                .padding(.bottom, 8)
            }
            .navigationTitle("Tuner")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                detector.referenceA = referenceA
                detector.start()
            }
            .onDisappear { detector.stop() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    #if os(iOS)
    private static let micOff = "Microphone access is off for Fonn — turn it on in Settings → Privacy → Microphone."
    #else
    private static let micOff = "Microphone access is off for Fonn — turn it on in System Settings → Privacy & Security → Microphone."
    #endif

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

/// The −50…+50 cent scale with a needle.
struct CentsDial: View {
    let cents: Double?
    let colour: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centre = width / 2
            let position = centre + CGFloat((cents ?? 0) / 50) * (width / 2 - 12)

            ZStack(alignment: .topLeading) {
                // Ticks every 10 cents, taller at 0 and ±50.
                ForEach(Array(stride(from: -50, through: 50, by: 10)), id: \.self) { tick in
                    let x = centre + CGFloat(tick) / 50 * (width / 2 - 12)
                    let major = tick == 0 || abs(tick) == 50
                    Rectangle()
                        .fill(tick == 0 ? Color.green.opacity(0.8) : Color.secondary.opacity(0.4))
                        .frame(width: major ? 2 : 1, height: major ? 34 : 20)
                        .position(x: x, y: 22)
                }

                // In-tune band
                Rectangle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: (width / 2 - 12) * 0.2, height: 40)
                    .position(x: centre, y: 22)

                // Needle
                if cents != nil {
                    Capsule()
                        .fill(colour)
                        .frame(width: 4, height: 52)
                        .position(x: position, y: 26)
                        .animation(.easeOut(duration: 0.12), value: position)
                }

                HStack {
                    Text("♭").foregroundStyle(.secondary)
                    Spacer()
                    Text("in tune").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("♯").foregroundStyle(.secondary)
                }
                .font(.title3)
                .padding(.horizontal, 4)
                .position(x: centre, y: 72)
            }
        }
    }
}
