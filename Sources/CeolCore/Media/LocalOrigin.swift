import Foundation
import Network

/// A web server on the loopback address, so a page in a web view has a real
/// origin.
///
/// **Why this exists, at length, because it is not obvious and I got it wrong
/// twice.**
///
/// The Pi plays every YouTube link. Its markup is the plainest thing possible
/// (`app.js`, line 2985): an `<iframe>` pointing at
/// `youtube-nocookie.com/embed/ID`. No player API, no negotiation. It works
/// because the Pi is a web server: the page lives at
/// `https://ceol-pi.tail01672f.ts.net:8443`, and the iframe's request arrives
/// carrying that origin. YouTube checks it, finds a real address, and plays.
///
/// The app has no address. `loadHTMLString(_:baseURL:)` sets a *document* base
/// URL, which is enough for relative paths and for `document.domain` — and it
/// is not an origin. The request to YouTube goes out with nothing to check, and
/// the player answers **error 152 or 153**.
///
/// Those two codes are the whole misunderstanding. 101 and 150 are the
/// documented "the uploader will not allow embedding" errors, and they are
/// final: nothing can play those but YouTube itself. 152 and 153 are an origin
/// the player would not accept, and they are *ours to fix*. I read the second
/// pair as the first, told Callum the uploaders had blocked the videos, and put
/// a "Watch on YouTube" button behind it. The videos were fine. The app was the
/// problem.
///
/// So: serve the page. Bound to 127.0.0.1 on a port the system picks, listening
/// only while the app is running, serving only the handful of files already in
/// this bundle's `Web/` folder. The web view then loads
/// `http://127.0.0.1:PORT/youtube.html`, which is an origin like any other, and
/// YouTube treats it the way it treats every developer's machine.
///
/// A loopback address is exempt from App Transport Security, so plain `http` is
/// fine and no exception is needed in either Info.plist.
public final class LocalOrigin: @unchecked Sendable {

    public static let shared = LocalOrigin()

    private let queue = DispatchQueue(label: "fonn.localorigin")
    private var listener: NWListener?
    private var port: UInt16?

    private init() {}

    /// The address of a bundled page, starting the server if it is not running.
    /// Returns nil if the server could not start, so callers can fall back to
    /// the old `loadHTMLString` route rather than showing nothing.
    public func url(forPage name: String) -> URL? {
        guard let port = start() else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/\(name).html")
    }

    /// The port, once the listener is ready. Nil means it never started.
    @discardableResult
    public func start() -> UInt16? {
        // The Mac target needs `ENABLE_INCOMING_NETWORK_CONNECTIONS = YES` for
        // this to bind at all. The sandbox blocks `listen()` without it even on
        // the loopback address, and the failure is silent — `NWListener` simply
        // never reaches `.ready` and every video falls back to the old route.
        queue.sync { () -> Void in
            guard listener == nil else { return }
            // `.any` asks the system for a free port. A fixed one would clash
            // with whatever else the machine is running — and on this machine
            // that could easily be the Pi's own app.
            guard let listener = try? NWListener(using: .tcp, on: .any) else { return }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .global())
                self?.receive(on: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = listener.port?.rawValue
                // iOS tears the socket down when the app is suspended, and a
                // dead listener that is still non-nil would mean every video
                // after the first backgrounding falls back to the broken route
                // — with nothing on screen to say why. Forgetting it here means
                // the next `start()` simply builds a new one.
                case .failed, .cancelled:
                    self?.listener = nil
                    self?.port = nil
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        }
        // The listener becomes ready on its own queue a moment after starting,
        // so the first caller has to wait for it. Ugly, but bounded at a
        // second, happens once per launch, and the alternative is handing the
        // web view a nil URL the first time a video is opened.
        //
        // Read through the queue rather than touching `port` directly: it is
        // written by `stateUpdateHandler` on that queue, and a plain read from
        // the main thread is a data race however harmless it looks.
        var waited = 0
        while waited < 200 {
            if let ready = queue.sync(execute: { port }) { return ready }
            Thread.sleep(forTimeInterval: 0.005)
            waited += 1
        }
        return queue.sync { port }
    }

    // MARK: - The smallest HTTP server that will do

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            guard let data, !data.isEmpty, error == nil else {
                if done || error != nil { connection.cancel() }
                return
            }
            let request = String(decoding: data, as: UTF8.self)
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        // "GET /youtube.html HTTP/1.1" — the first line is all that matters.
        let path = request.split(separator: "\r\n").first
            .flatMap { $0.split(separator: " ").dropFirst().first }
            .map(String.init) ?? "/"

        // Only ever a plain name inside this bundle's Web folder. `lastPathComponent`
        // makes `../../` impossible, which matters even on loopback: anything
        // else on this Mac can reach this port.
        let name = (path.split(separator: "?").first.map(String.init) ?? path)
        let file = URL(fileURLWithPath: name).lastPathComponent
        let stem = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension

        guard !stem.isEmpty,
              let url = Bundle.module.url(forResource: stem,
                                          withExtension: ext.isEmpty ? "html" : ext,
                                          subdirectory: "Web"),
              let body = try? Data(contentsOf: url) else {
            send(status: "404 Not Found", type: "text/plain", body: Data("Not here".utf8), on: connection)
            return
        }
        send(status: "200 OK", type: contentType(ext), body: body, on: connection)
    }

    private func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "": return "text/html; charset=utf-8"
        case "js":       return "text/javascript; charset=utf-8"
        case "css":      return "text/css; charset=utf-8"
        case "mp3":      return "audio/mpeg"
        case "json":     return "application/json"
        default:         return "application/octet-stream"
        }
    }

    private func send(status: String, type: String, body: Data, on connection: NWConnection) {
        let head = """
            HTTP/1.1 \(status)\r
            Content-Type: \(type)\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r\n
            """
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
