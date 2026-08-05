import SwiftUI

/// The circle of fifths, drawn, on either machine.
///
/// Majors on the outer ring, their relative minors inside, sharpwards
/// clockwise from C at the top — the arrangement every printed copy uses, so
/// it reads without a legend. Each position carries the number of tunes you
/// have in it, which is the fact a printed circle does not carry and the one
/// that makes this a tool rather than a poster.
///
/// It lives in CeolCore rather than in one app because it is pure SwiftUI —
/// no `NSViewRepresentable` twin, nothing platform-shaped — and because a
/// second copy of the geometry is a second copy to get wrong. The only thing
/// it knows about tunes is how many are at each position; the counting is the
/// caller's business.
public struct CircleOfFifthsWheel: View {
    /// Signature → how many tunes you have there.
    public let counts: [Int: Int]
    /// Signature → why it follows from where you are. Empty means nothing is
    /// picked yet and every position is open.
    public let open: [Int: String]
    @Binding public var focused: Int?

    /// Phone-sized: no tune counts on the chips and a tighter inner ring.
    ///
    /// On a 390pt screen the count under the key name turns each chip into two
    /// lines of very small type, and the number is not what you are looking at
    /// when your thumb is on its way to a key.
    public var compact: Bool = false

    public init(counts: [Int: Int], open: [Int: String],
                focused: Binding<Int?>, compact: Bool = false) {
        self.counts = counts
        self.open = open
        self._focused = focused
        self.compact = compact
    }

    public var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                ForEach(CircleOfFifths.wheel, id: \.self) { sig in
                    position(sig, side: side, centre: centre)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func position(_ sig: Int, side: CGFloat, centre: CGPoint) -> some View {
        // C at twelve o'clock, one twelfth of a turn per step. A position's
        // angle is its signature, not its index in the array — which is the
        // whole reason `CircleOfFifths.wheel` holds signatures.
        let angle = Angle.degrees(Double(sig) * 30 - 90)
        let outer = point(from: centre, radius: side * 0.38, angle: angle)
        let inner = point(from: centre, radius: side * (compact ? 0.20 : 0.22), angle: angle)
        let lit = open.isEmpty || open[sig] != nil
        return ZStack {
            if let major = CircleOfFifths.major(atSignature: sig) {
                chip(major, at: outer, lit: lit, sig: sig, big: true, side: side)
            }
            if let minor = CircleOfFifths.minor(atSignature: sig) {
                chip(minor, at: inner, lit: lit, sig: sig, big: false, side: side)
            }
        }
    }

    /// Chip sizes are a fraction of the wheel, not fixed points.
    ///
    /// Twelve positions round a ring of radius 0.38·side leaves about 0.2·side
    /// between neighbours, so a fixed 54pt chip overlaps as soon as the wheel
    /// is under about 300pt — and on a phone it always is.
    private func chip(_ keyName: String, at centre: CGPoint,
                      lit: Bool, sig: Int, big: Bool, side: CGFloat) -> some View {
        let count = counts[sig] ?? 0
        let isFocused = focused == sig
        let width = side * (big ? 0.16 : 0.12)
        let nameSize = side * (big ? 0.045 : 0.036)
        return Button {
            // Tapping the position you are already on lets go of it, which is
            // the only way back to seeing every onward move at once.
            focused = isFocused ? nil : sig
        } label: {
            VStack(spacing: 0) {
                Text(CircleOfFifths.badge(keyName)
                        .replacingOccurrences(of: " Major", with: "")
                        .replacingOccurrences(of: " Minor", with: "m"))
                    .font(.system(size: nameSize, weight: big ? .semibold : .regular))
                if big && count > 0 && !compact {
                    Text("\(count)")
                        .font(.system(size: nameSize * 0.78).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, height: width)
            .background(
                Circle().fill(isFocused ? Color.accentColor.opacity(0.25)
                                        : Color.gray.opacity(0.15))
            )
            .overlay(
                Circle().strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2)
            )
            // Quiet rather than hidden: a position with no tunes in it is still
            // information — it says where your library isn't.
            .opacity(lit ? (count == 0 ? 0.35 : 1) : 0.15)
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        #if os(macOS)
        // Hover has no meaning on a phone, and the label is the only thing
        // there is room for anyway.
        .help(helpText(keyName, count: count, sig: sig))
        #endif
        .position(centre)
    }

    private func helpText(_ keyName: String, count: Int, sig: Int) -> String {
        let name = CircleOfFifths.badge(keyName)
        guard count > 0 else { return "\(name) — no tunes here" }
        if let why = open[sig] { return "\(name) — \(count) tunes · \(why.lowercased())" }
        return "\(name) — \(count) tunes"
    }

    private func point(from centre: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(x: centre.x + radius * cos(angle.radians),
                y: centre.y + radius * sin(angle.radians))
    }
}

public extension CircleOfFifths {
    /// Tunes per position, ready for the wheel.
    static func counts(_ index: [String: [Tune]]) -> [Int: Int] {
        var totals: [Int: Int] = [:]
        for sig in wheel {
            totals[sig] = keys(withSignature: sig)
                .reduce(0) { $0 + (index[$1.lowercased()]?.count ?? 0) }
        }
        return totals
    }
}
