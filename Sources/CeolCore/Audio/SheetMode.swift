import Foundation
import SwiftUI

// FONN-SHEETMODE-1
/// Sheet music mode: Fonn as a music stand, on iOS and the Mac alike.
///
/// The music fills the page with no playback controls; you zoom it and scroll
/// it by hand, and a bar under it has the metronome — always clicking on its
/// own here — and Scroll, which moves the music up the page in time with the
/// metronome. Recordings and Apple Music, Spotify and Bandcamp still play in
/// the strip under the music.
///
/// One of these per screen showing music. Whether the mode is on is kept, so
/// once you use Fonn as a music stand it stays one from tune to tune until you
/// turn it off; scrolling, speed and zoom start afresh on each tune.
///
/// The page does the work (Web/sheetmode.js); this is the state, and the line
/// of JavaScript that hands it over.
@MainActor
public final class SheetMode: ObservableObject {

    public static let key = "fonn.sheetMode"

    @Published public var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            UserDefaults.standard.set(isOn, forKey: Self.key)
            if !isOn { scrolling = false; zoom = 1; factor = 1 }
        }
    }
    /// Scrolling now. The page turns it off itself at the end of the music.
    @Published public var scrolling = false
    /// The reader's own Slower / Faster, on top of the metronome's tempo.
    @Published public var factor: Double = 1
    /// How far the music is zoomed, 1 being the size it is drawn at.
    @Published public var zoom: Double = 1

    public init() {
        isOn = UserDefaults.standard.bool(forKey: Self.key)
    }

    public static let slowest = 0.5
    public static let fastest = 2.0

    public func slower() { factor = max(Self.slowest, (factor / 1.1 * 100).rounded() / 100) }
    public func faster() { factor = min(Self.fastest, (factor * 1.1 * 100).rounded() / 100) }
    public func inTime() { factor = 1 }

    public func zoomIn() { zoom = min(3, (zoom * 1.15 * 100).rounded() / 100) }
    public func zoomOut() { zoom = max(0.5, (zoom / 1.15 * 100).rounded() / 100) }
    public func actualSize() { zoom = 1 }

    /// "In time", or how far off it the reader has set it.
    public var speedLabel: String {
        let pct = Int((factor * 100).rounded())
        if pct == 100 { return "In time" }
        return "\(pct)%"
    }

    /// The JavaScript that brings the page into line. Sent whenever it comes
    /// out different from the last one sent; every call in it is safe to repeat.
    public func script(bpm: Int) -> String {
        let f = String(format: "%.3f", factor)
        let z = String(format: "%.3f", zoom)
        return "if (typeof ceolSheetMode === 'function') {"
            + " ceolSheetMode(\(isOn));"
            + " if (\(isOn)) { ceolSheetZoom(\(z)); ceolSheetScrollRate(\(bpm), \(f));"
            + " ceolSheetScroll(\(scrolling), \(bpm), \(f)); } }"
    }

    /// What the page says back: the end of the music, or a pinch.
    public func receive(_ body: Any) {
        guard let d = body as? [String: Any] else { return }
        if let s = d["scrolling"] as? Bool, s != scrolling { scrolling = s }
        if let z = (d["zoom"] as? NSNumber)?.doubleValue, abs(z - zoom) > 0.001 { zoom = z }
    }
}
