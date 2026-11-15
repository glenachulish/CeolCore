import Foundation
import QuartzCore

// FONN-ABCFOLLOW-1

/// The beats of the ABC tune as it is actually played, and where the playing
/// has got to — so the metronome clicks with the tune rather than merely at
/// its tempo.
///
/// The music page sends the bars in playing order (repeats, endings, a set's
/// tunes one after another), each with its start, the length of a full bar of
/// that tune, its beats and whether they are compound. From those the click
/// is laid out bar by bar, so a pickup is counted as the end of a bar, not as
/// "one", and a short last bar before a repeat carries its count into the
/// pickup that follows it.
///
/// Where the playing is comes from one of two places. On the phone the app's
/// own player plays the rendered tune and knows its position to the sample
/// (`nativeClock`). Otherwise — the Mac, or the phone with "Play through the
/// system" off — abcjs plays it inside the page, and the page reports its
/// position ten times a second (`pageClock`), smoothed here so that the
/// jitter of the messages isn't heard as jitter in the click.
@MainActor
public final class TuneBeats {
    public struct Bar: Equatable, Sendable {
        /// Where the bar begins, in seconds of the tune as played.
        public var start: Double
        /// How long a full bar of this tune lasts.
        public var full: Double
        /// Beats in the bar as counted: 2 in a reel or a jig, 3 in a waltz.
        public var beats: Int
        /// Clicks in a beat when the bar is counted out: 3 in compound time.
        public var sub: Int

        public init(start: Double, full: Double, beats: Int, sub: Int) {
            self.start = start
            self.full = full
            self.beats = max(1, beats)
            self.sub = max(1, sub)
        }
    }

    public private(set) var bars: [Bar] = []
    /// When the last bar ends.
    public private(set) var end: Double = 0
    /// Whether the app's player, not the page, is playing the tune.
    public private(set) var native = false

    /// Set by the sheet view: where the app's own player is.
    public var nativeClock: (@MainActor () -> Metronome.RecordingClock?)?

    weak var metronome: Metronome?

    private var pageSeconds: Double = 0
    private var pageAt: Double = 0
    private var pagePlaying = false
    private var pageSeen = false

    public init() {}

    public var hasBars: Bool { !bars.isEmpty }

    /// The page's `beats` message: { bars: [[startMs, fullMs, beats, sub]],
    /// end: ms, native: bool }.
    public func receive(_ body: [String: Any]) {
        guard let raw = body["bars"] as? [[Any]] else { return }
        var out: [Bar] = []
        for row in raw where row.count >= 4 {
            guard let start = (row[0] as? NSNumber)?.doubleValue,
                  let full = (row[1] as? NSNumber)?.doubleValue,
                  let beats = (row[2] as? NSNumber)?.intValue,
                  let sub = (row[3] as? NSNumber)?.intValue,
                  full > 0 else { continue }
            out.append(Bar(start: start / 1000, full: full / 1000, beats: beats, sub: sub))
        }
        let newEnd = ((body["end"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let newNative = body["native"] as? Bool ?? false
        guard out != bars || newEnd != end || newNative != native else { return }
        bars = out
        end = newEnd
        native = newNative
        metronome?.tuneBeatsChanged()
    }

    /// The page's `beatClock` message: { ms, playing }.
    public func pageClock(_ body: [String: Any]) {
        guard let ms = (body["ms"] as? NSNumber)?.doubleValue else { return }
        let playing = body["playing"] as? Bool ?? false
        let reported = ms / 1000
        let now = CACurrentMediaTime()
        if playing && pagePlaying && pageSeen {
            let predicted = pageSeconds + (now - pageAt)
            let off = reported - predicted
            // Small differences are the messages' own jitter: lean towards
            // them gently. A large one is a seek or a loop: take it as it is.
            pageSeconds = abs(off) < 0.08 ? predicted + off * 0.1 : reported
        } else {
            pageSeconds = reported
        }
        pageAt = now
        pagePlaying = playing
        pageSeen = true
    }

    /// Where the tune is, for the metronome to follow.
    public var clock: Metronome.RecordingClock? {
        if native { return nativeClock?() }
        guard pageSeen else { return nil }
        let seconds = pagePlaying ? pageSeconds + (CACurrentMediaTime() - pageAt) : pageSeconds
        return Metronome.RecordingClock(seconds: seconds, rate: 1, playing: pagePlaying)
    }

    /// The clicks for `bars`, `clicks(bar)` of them to a full bar, each with
    /// its place in the bar (0 is one).
    ///
    /// A full bar clicks from its start. A short bar is one of three things:
    /// - the rest of a bar begun by the short bar before it (a part ending
    ///   short, then the pickup into the repeat): the count carries on;
    /// - a pickup, when a full bar follows: its clicks are the END of a bar;
    /// - otherwise (a short last bar): clicked from its start.
    public static func grid(bars: [Bar], end: Double, clicks: (Bar) -> Int) -> BeatGrid? {
        guard !bars.isEmpty else { return nil }
        func next(_ i: Int) -> Double {
            i + 1 < bars.count ? bars[i + 1].start : max(end, bars[i].start + bars[i].full)
        }
        func isFull(_ i: Int) -> Bool {
            guard i < bars.count else { return false }
            return next(i) - bars[i].start > bars[i].full * 0.9
        }
        var times: [Double] = []
        var places: [Int] = []
        var most = 1
        var carry: Int? = nil
        for i in bars.indices {
            let bar = bars[i]
            let n = max(1, clicks(bar))
            most = max(most, n)
            let length = bar.full / Double(n)
            let ends = next(i)
            let fit = min(n, max(0, Int(((ends - bar.start) / length).rounded())))
            guard fit > 0 else { continue }
            if fit == n {
                for j in 0..<n {
                    times.append(bar.start + Double(j) * length)
                    places.append(j)
                }
                carry = nil
            } else if let counted = carry, counted + fit <= n {
                for j in 0..<fit {
                    times.append(bar.start + Double(j) * length)
                    places.append(counted + j)
                }
                carry = counted + fit < n ? counted + fit : nil
            } else if isFull(i + 1) && (i == 0 || fit * 2 <= n) {
                for j in 0..<fit {
                    times.append(ends - Double(fit - j) * length)
                    places.append(n - fit + j)
                }
                carry = nil
            } else {
                for j in 0..<fit {
                    times.append(bar.start + Double(j) * length)
                    places.append(j)
                }
                carry = fit
            }
        }
        guard !times.isEmpty else { return nil }
        return BeatGrid(times: times, places: places, beatsPerBar: most)
    }
}
