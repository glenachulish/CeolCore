import Foundation

// FONN-BEAT-2
/// The time signature that came with the page's last tempo report.
///
/// The music page tells the app its tempo through each sheet view's `onTempo`,
/// which carries a tempo and a count of beats. The metronome now needs the
/// time signature too, and adding a third value to `onTempo` would mean
/// changing four sheet views and every screen that hosts one. So the sheet
/// view leaves the signature here in the line before it calls `onTempo`, and
/// `Metronome.tempoFromTune` picks it up and clears it in the same breath —
/// both on the main thread, one straight after the other, so nothing else can
/// come between.
public enum TuneMeterReport {
    nonisolated(unsafe) public static var latest: String?
}
