import SwiftUI

// FONN-EMBEDLOOP-1
/// An A–B loop for the Bandcamp and Spotify players in the strip.
///
/// Neither service lets an app drive its player, but the strip loads each
/// player as the web view's own page, so a script of ours runs inside it. It
/// looks for the page's <audio> or <video>, and loops that: when the time
/// passes B it sets it back to A. Bandcamp plays an ordinary stream, so this
/// should work there. Spotify's may not let its time be set; if the script
/// finds no element it can use, the bar simply never appears.
///
/// The page reports back on the strip's own "fonnEmbed" channel with a
/// dictionary ({loop: true, found, a, b, looping}); the old "play" string on
/// the same channel still means "sound started".
public struct EmbedLoopState: Equatable {
    public var found = false
    public var a: Double?
    public var b: Double?
    public var looping = false

    public init() {}

    public init?(message body: Any) {
        guard let d = body as? [String: Any], d["loop"] != nil else { return nil }
        found = (d["found"] as? Bool) ?? false
        let a = (d["a"] as? Double) ?? -1
        let b = (d["b"] as? Double) ?? -1
        self.a = a >= 0 ? a : nil
        self.b = b >= 0 ? b : nil
        looping = (d["looping"] as? Bool) ?? false
    }
}

public enum EmbedLoop {

    /// Injected at document end into the player page (main frame).
    public static let script = """
    (function () {
      if (window.fonnLoop) return;
      var A = null, B = null, looping = false, media = null, last = "";
      function post() {
        var msg = { loop: true, found: !!media, a: A === null ? -1 : A,
                    b: B === null ? -1 : B, looping: looping };
        var key = JSON.stringify(msg);
        if (key === last) return;
        last = key;
        try { window.webkit.messageHandlers.fonnEmbed.postMessage(msg); } catch (e) {}
      }
      function find() {
        var list = document.querySelectorAll('audio,video');
        for (var i = 0; i < list.length; i++) {
          if (list[i].currentSrc || list[i].src) return list[i];
        }
        return null;
      }
      function check() {
        if (!looping || !media || A === null) return;
        var end = B !== null ? B : (media.duration || 0) - 0.25;
        if (end > 0 && media.currentTime >= end) {
          try { media.currentTime = A; } catch (e) {}
        }
      }
      setInterval(function () {
        var m = find();
        if (m && m !== media) { media = m; }
        check();
        post();
      }, 100);
      window.fonnLoop = function (v) {
        if (!media) { media = find(); if (!media) return; }
        var t = media.currentTime || 0;
        if (v === 'a') {
          A = t;
          if (B !== null && B <= A + 0.3) B = null;
          if (B !== null) looping = true;
        } else if (v === 'b') {
          if (A === null) A = 0;
          if (t > A + 0.3) {
            B = t; looping = true;
            try { media.currentTime = A; media.play(); } catch (e) {}
          }
        } else if (v === 'a-') { if (A !== null) A = Math.max(0, A - 0.5); }
        else if (v === 'a+') { if (A !== null && (B === null || A + 0.5 < B - 0.3)) A += 0.5; }
        else if (v === 'b-') { if (B !== null && B - 0.5 > A + 0.3) B -= 0.5; }
        else if (v === 'b+') { if (B !== null) B += 0.5; }
        else if (v === 'toggle') {
          if (A !== null) {
            looping = !looping;
            if (looping) { try { media.currentTime = A; media.play(); } catch (e) {} }
          }
        } else if (v === 'clear') { A = null; B = null; looping = false; }
        post();
      };
    })();
    """

    /// The JavaScript to send for a button: a, b, a-, a+, b-, b+, toggle, clear.
    public static func command(_ verb: String) -> String {
        "if (window.fonnLoop) window.fonnLoop('\(verb)');"
    }

    public static func time(_ t: Double?) -> String {
        guard let t else { return "–" }
        let m = Int(t) / 60
        return String(format: "%d:%04.1f", m, t - Double(m * 60))
    }
}

/// The row of loop controls under the Bandcamp or Spotify player.
public struct EmbedLoopBar: View {
    let state: EmbedLoopState
    let send: (String) -> Void

    public init(state: EmbedLoopState, send: @escaping (String) -> Void) {
        self.state = state
        self.send = send
    }

    public static let height: CGFloat = 34

    public var body: some View {
        HStack(spacing: 6) {
            nudge("chevron.left", "a-", "Move A earlier", enabled: state.a != nil)
            end("A", set: state.a != nil, verb: "a", label: "Set A, the start of the loop, here")
            Text(EmbedLoop.time(state.a)).monospacedDigit().foregroundStyle(.secondary)
            nudge("chevron.right", "a+", "Move A later", enabled: state.a != nil)

            Button { send("toggle") } label: {
                Label(state.looping ? "Looping" : "Loop", systemImage: "repeat")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(state.looping ? Color.black : FonnColour.loop)
                    .background(FonnColour.loop.opacity(state.looping ? 1 : 0.2), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(state.a == nil)
            .accessibilityLabel(state.looping ? "Stop looping" : "Loop between A and B")

            nudge("chevron.left", "b-", "Move B earlier", enabled: state.b != nil)
            Text(EmbedLoop.time(state.b)).monospacedDigit().foregroundStyle(.secondary)
            end("B", set: state.b != nil, verb: "b", label: "Set B, the end of the loop, here")
            nudge("chevron.right", "b+", "Move B later", enabled: state.b != nil)

            Button { send("clear") } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(state.a == nil && state.b == nil)
                .accessibilityLabel("Clear the loop")
        }
        .font(.caption)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
    }

    private func end(_ letter: String, set: Bool, verb: String, label: String) -> some View {
        Button { send(verb) } label: {
            Text(letter)
                .font(.caption.weight(.bold))
                .frame(minWidth: 26)
                .padding(.vertical, 4)
                .foregroundStyle(set ? Color.white : Color.primary)
                .background(set ? FonnColour.loop : Color.secondary.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func nudge(_ symbol: String, _ verb: String, _ label: String, enabled: Bool) -> some View {
        Button { send(verb) } label: { Image(systemName: symbol).font(.caption2) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!enabled)
            .accessibilityLabel(label)
    }
}
