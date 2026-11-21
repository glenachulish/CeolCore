import SwiftUI

// FONN-COLOURS-1
/// One colour per job, the same on the phone, the Mac and the music pages
/// (abcjs-audio.css, abc.html), so a control can be found by its colour
/// alone at a session, with a flute in your hands and no time to read:
/// play green (red while playing, to stop), loop orange, speed and transpose
/// blue, metronome red (as it always was when on), drone purple, sound teal,
/// tuner indigo, start a set green; hitlist orange and favourite red, as
/// before.
public enum FonnColour {
    public static let play = Color.green
    public static let stop = Color.red
    public static let loop = Color.orange
    public static let speed = Color.blue
    public static let transpose = Color.blue
    public static let metronome = Color.red
    public static let drone = Color.purple
    public static let sound = Color.teal
    public static let tuner = Color.indigo
    public static let startSet = Color.green
    public static let record = Color.red
}

public extension View {
    /// A control in its colour, on a soft pill of the same colour that fills
    /// in more strongly while the thing is on — so on and off can be told
    /// apart at a glance without reading anything.
    func fonnChip(_ colour: Color, on: Bool = false) -> some View {
        self
            .foregroundStyle(colour)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colour.opacity(on ? 0.28 : 0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(colour.opacity(on ? 0.9 : 0), lineWidth: 1.5))
    }
}
