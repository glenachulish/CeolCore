import AVFoundation
import Accelerate
import Foundation

// FONN-BEATS-1

/// Where the beats fall in a recording, in seconds from its start, at normal
/// speed.
///
/// Either a list found by `BeatDetector` — which follows a recording that
/// speeds up or slows down, as live playing does — or an even grid from a
/// tempo and one moment where a bar begins, which is what tapping gives.
public struct BeatGrid: Sendable, Equatable {
    /// Beat times found in the recording. Empty for an even grid.
    public let times: [Double]
    /// Seconds per beat at normal speed: the average, for a found grid.
    public let period: Double
    /// For an even grid, a moment where a bar begins. For a found grid, the
    /// index in `times` of a beat that begins a bar.
    public let anchor: Double
    public let firstDownbeat: Int
    public let beatsPerBar: Int

    /// Tempo at normal speed, in the beats the tune is counted in.
    public var bpm: Double { 60 / period }

    /// An even grid: `bpm` at normal speed, with a bar beginning at `downbeat`.
    public init(bpm: Double, downbeat: Double, beatsPerBar: Int) {
        times = []
        period = 60 / max(20, bpm)
        anchor = downbeat
        firstDownbeat = 0
        self.beatsPerBar = max(1, beatsPerBar)
    }

    /// A grid found in the recording.
    public init(times: [Double], firstDownbeat: Int, beatsPerBar: Int) {
        self.times = times
        let span = (times.last ?? 0) - (times.first ?? 0)
        period = times.count > 1 ? span / Double(times.count - 1) : 0.5
        anchor = times.isEmpty ? 0 : times[max(0, min(firstDownbeat, times.count - 1))]
        self.firstDownbeat = max(0, firstDownbeat)
        self.beatsPerBar = max(1, beatsPerBar)
    }

    /// The same beats with the bar starting on the beat nearest `moment` —
    /// for "Tap on one" when the finder chose the wrong beat for one.
    public func withDownbeat(near moment: Double) -> BeatGrid {
        if times.isEmpty {
            return BeatGrid(bpm: bpm, downbeat: moment, beatsPerBar: beatsPerBar)
        }
        var best = 0
        var gap = Double.infinity
        for (index, time) in times.enumerated() where abs(time - moment) < gap {
            gap = abs(time - moment)
            best = index
        }
        return BeatGrid(times: times, firstDownbeat: best, beatsPerBar: beatsPerBar)
    }

    /// A moment where a bar begins, to keep on the recording.
    public var downbeatMoment: Double { anchor }

    /// Beats from `start` (inclusive) to `end` (exclusive), each with where
    /// it falls in the bar (0 is one). Past the ends of a found grid the
    /// average period carries on, so a loop round the end still clicks.
    public func beats(from start: Double, to end: Double) -> [(time: Double, inBar: Int)] {
        guard end > start, period > 0 else { return [] }
        var out: [(time: Double, inBar: Int)] = []
        let bar = beatsPerBar
        func place(_ index: Int) -> Int { ((index % bar) + bar) % bar }

        if times.isEmpty {
            var k = Int((start - anchor) / period)
            while anchor + Double(k) * period < start { k += 1 }
            while true {
                let time = anchor + Double(k) * period
                if time >= end { break }
                out.append((time, place(k)))
                k += 1
            }
            return out
        }

        let first = times[0], last = times[times.count - 1]
        // Before the first found beat.
        if start < first {
            var k = -1
            while first + Double(k) * period >= start { k -= 1 }
            k += 1
            while k < 0 {
                let time = first + Double(k) * period
                if time >= end { return out }
                out.append((time, place(k - firstDownbeat)))
                k += 1
            }
        }
        // The found beats: binary search for the first at or after start.
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < start { lo = mid + 1 } else { hi = mid }
        }
        var index = lo
        while index < times.count, times[index] < end {
            out.append((times[index], place(index - firstDownbeat)))
            index += 1
        }
        // After the last.
        if end > last + period * 0.5 {
            var k = 1
            while true {
                let time = last + Double(k) * period
                if time >= end { break }
                if time >= start {
                    out.append((time, place(times.count - 1 + k - firstDownbeat)))
                }
                k += 1
            }
        }
        return out
    }
}

/// Finds the beat in a recording of your own.
///
/// How, in four steps — tested on rendered jigs and reels, steady and
/// drifting, before it was written here:
/// 1. **Where notes change.** The recording is mixed to mono at about 11 kHz
///    and cut into overlapping 93 ms frames every 11.6 ms; the rise in the
///    log spectrum from frame to frame marks a new note even when it is
///    slurred, as fiddle and flute often are.
/// 2. **The tempo.** That line is compared with itself shifted; the shift
///    with the most in common is the beat. Its subdivision (three in a jig,
///    two in a reel), twice it and a whole bar are counted too, and the
///    usual tempo for the tune type is preferred, gently — without that a
///    jig is as likely to be heard in fours as in threes.
/// 3. **The beats.** A beat tracker (Ellis's dynamic programming) picks the
///    strongest note changes that keep to about that tempo, allowing it to
///    drift as players do.
/// 4. **Where one is.** The beat of the bar on which notes change most
///    strongly. This is the weakest step; "Tap on one" corrects it.
public enum BeatDetector {
    public enum Failure: LocalizedError {
        case unreadable, tooShort, noBeat
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "This recording couldn't be read."
            case .tooShort: return "The recording is too short to find a beat in."
            case .noBeat: return "No steady beat was found."
            }
        }
    }

    private static let targetRate = 11_025.0
    private static let frameSize = 1024
    private static let hop = 128

    /// Find the beat. `beatsPerBar` and `subdivision` are how the tune is
    /// counted (2 and 3 for a jig, 4 and 2 for a reel); `expectedBPM` is the
    /// usual tempo for it, in the same beats.
    public static func analyse(url: URL, beatsPerBar: Int, subdivision: Int,
                               expectedBPM: Double) throws -> BeatGrid {
        let (samples, rate) = try readMono(url)
        guard Double(samples.count) / rate > 6 else { throw Failure.tooShort }
        let onsets = onsetStrength(samples)
        let secondsPerFrame = Double(hop) / rate
        let period = tempoPeriod(onsets, secondsPerFrame: secondsPerFrame,
                                 expectedBPM: max(30, expectedBPM),
                                 subdivision: max(1, subdivision),
                                 beatsPerBar: max(1, beatsPerBar))
        guard period > 2 else { throw Failure.noBeat }
        let frames = trackBeats(onsets, period: period)
        guard frames.count >= 8 else { throw Failure.noBeat }

        let bar = max(1, beatsPerBar)
        var best = 0
        var bestStrength = -Double.infinity
        for phase in 0..<bar {
            var total = 0.0, count = 0.0
            var index = phase
            while index < frames.count {
                total += Double(onsets[frames[index]])
                count += 1
                index += bar
            }
            let mean = count > 0 ? total / count : 0
            if mean > bestStrength { bestStrength = mean; best = phase }
        }
        let centre = Double(frameSize) / 2
        let times = frames.map { (Double($0 * hop) + centre) / rate }
        return BeatGrid(times: times, firstDownbeat: best, beatsPerBar: bar)
    }

    // MARK: - Steps

    /// The recording as mono, averaged down to about 11 kHz.
    private static func readMono(_ url: URL) throws -> ([Float], Double) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadable }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else { throw Failure.unreadable }
        let factor = max(1, Int((format.sampleRate / targetRate).rounded()))
        let rate = format.sampleRate / Double(factor)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw Failure.unreadable
        }
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) / factor + 1)
        var sum: Float = 0
        var count = 0
        let scale = 1 / Float(channels * factor)
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                for channel in 0..<channels { sum += data[channel][frame] }
                count += 1
                if count == factor {
                    out.append(sum * scale)
                    sum = 0
                    count = 0
                }
            }
        }
        guard !out.isEmpty else { throw Failure.unreadable }
        return (out, rate)
    }

    /// How strongly the sound changes, frame by frame, with the slow swell
    /// taken out and only rises kept.
    private static func onsetStrength(_ samples: [Float]) -> [Float] {
        let n = frameSize
        let half = n / 2
        let frames = (samples.count - n) / hop
        guard frames > 2 else { return [] }
        let log2n = vDSP_Length(10)          // 1024
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var current = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var flux = [Float](repeating: 0, count: frames)

        for index in 0..<frames {
            let start = index * hop
            samples.withUnsafeBufferPointer { source in
                window.withUnsafeBufferPointer { w in
                    frame.withUnsafeMutableBufferPointer { f in
                        vDSP_vmul(source.baseAddress! + start, 1, w.baseAddress!, 1,
                                  f.baseAddress!, 1, vDSP_Length(n))
                    }
                }
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // zrip's result is twice numpy's rfft, which the
                    // compression below was tuned against; hence the half.
                    for k in 0..<half {
                        let magnitude = 0.5 * (rp[k] * rp[k] + ip[k] * ip[k]).squareRoot()
                        current[k] = log1p(100 * magnitude)
                    }
                }
            }
            if index > 0 {
                var rise: Float = 0
                for k in 0..<half {
                    let d = current[k] - previous[k]
                    if d > 0 { rise += d }
                }
                flux[index] = rise
            }
            swap(&current, &previous)
        }

        // Take out the slow swell: subtract a 0.4 s running mean, keep rises.
        let width = max(1, Int(0.4 * targetRate / Double(hop)))
        var running = [Double](repeating: 0, count: frames + 1)
        for index in 0..<frames { running[index + 1] = running[index] + Double(flux[index]) }
        var out = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            let a = max(0, index - width / 2)
            let b = min(frames, index + width / 2 + 1)
            let mean = (running[b] - running[a]) / Double(b - a)
            out[index] = max(0, flux[index] - Float(mean))
        }
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(out, 1, nil, 1, &mean, &deviation, vDSP_Length(frames))
        if deviation > 0 {
            for index in 0..<frames { out[index] /= deviation }
        }
        return out
    }

    /// The beat's length in frames.
    private static func tempoPeriod(_ onsets: [Float], secondsPerFrame: Double,
                                    expectedBPM: Double, subdivision: Int,
                                    beatsPerBar: Int) -> Double {
        let count = onsets.count
        let shortest = Int(60 / 300 / secondsPerFrame)
        let longest = Int(60 / 30 / secondsPerFrame)
        let reach = min(count - 2, longest * beatsPerBar + 2)
        guard shortest > 1, reach > longest else { return 0 }

        // Autocorrelation at every shift that will be asked for.
        var correlation = [Double](repeating: 0, count: reach + 1)
        onsets.withUnsafeBufferPointer { o in
            for lag in 1...reach {
                var dot: Float = 0
                vDSP_dotpr(o.baseAddress!, 1, o.baseAddress! + lag, 1, &dot,
                           vDSP_Length(count - lag))
                correlation[lag] = Double(dot) / Double(count - lag)
            }
        }
        func at(_ lag: Double) -> Double {
            let i = Int(lag)
            guard i >= 0, i + 1 < correlation.count else { return 0 }
            let f = lag - Double(i)
            return correlation[i] * (1 - f) + correlation[i + 1] * f
        }

        var bestLag = shortest
        var bestScore = -Double.infinity
        var scores = [Double](repeating: 0, count: longest + 2)
        for lag in shortest...longest {
            let l = Double(lag)
            let raw = at(l) + 0.5 * at(l / Double(subdivision)) + 0.5 * at(2 * l)
                + 0.5 * at(Double(beatsPerBar) * l)
            let bpm = 60 / (l * secondsPerFrame)
            // A gentle preference for the usual tempo: 0.9 of an octave
            // either side, which the tests found keeps jigs out of fours and
            // fast reels out of half time.
            let octaves = log2(bpm / expectedBPM) / 0.9
            let score = raw * exp(-0.5 * octaves * octaves)
            scores[lag] = score
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // Between frames, by the parabola through the peak.
        if bestLag > shortest, bestLag < longest {
            let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
            let curve = a - 2 * b + c
            if curve != 0 { return Double(bestLag) + 0.5 * (a - c) / curve }
        }
        return Double(bestLag)
    }

    /// Ellis's beat tracker: the strongest path of note changes about one
    /// period apart, the penalty growing with how far a gap strays from it.
    private static func trackBeats(_ onsets: [Float], period: Double) -> [Int] {
        let count = onsets.count
        guard count > Int(period) * 2 else { return [] }
        let tightness = 300.0
        var score = onsets.map { Double($0) }
        var back = [Int](repeating: -1, count: count)
        for t in 0..<count {
            let earliest = max(0, Int(Double(t) - 2 * period))
            let latest = Int(Double(t) - period / 2)
            guard latest >= 0, latest >= earliest else { continue }
            var best = -Double.infinity
            var from = -1
            for tau in earliest...latest {
                let ratio = log(Double(t - tau) / period)
                let candidate = score[tau] - tightness * ratio * ratio
                if candidate > best { best = candidate; from = tau }
            }
            if from >= 0 {
                score[t] = Double(onsets[t]) + best
                back[t] = from
            }
        }
        let tail = max(0, count - Int(period))
        var end = tail
        for t in tail..<count where score[t] > score[end] { end = t }
        var beats: [Int] = []
        var t = end
        while t >= 0 {
            beats.append(t)
            t = back[t]
        }
        return beats.reversed()
    }
}
