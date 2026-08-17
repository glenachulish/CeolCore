import Foundation
import SwiftData

/// Fetching a tune's recordings straight off the Pi.
///
/// Every route into this library so far has gone through a folder: `rsync` the
/// Pi's uploads down, run `export-ceol-json.py`, import the result. That works
/// — it is how the 674 files got here — but it is four steps outside the app
/// for something the app can do itself, and it has to be repeated in full every
/// time one recording is added.
///
/// The names are already here: the web app wrote every attachment into the
/// tune's notes as `audio: /api/uploads/NAME`, which is what `LinkedText`
/// reads. So the app already knows exactly which files it is missing and
/// exactly what to ask for.
///
/// **It has to sign in first, and I missed that.** `GET /api/uploads/{filename}`
/// carries no dependency — `main.py` line 6605 is three lines that sanitise the
/// name and return the file — so I read it as public and said so. The check is
/// not on the route. It is a global HTTP middleware at line 1264 that demands a
/// `__Host-ceol_session` cookie for every path not on a short open list, and
/// `/api/uploads/` is not on that list. The first real run answered 401 to all
/// 630 files. Reading the endpoint was not reading the server.
///
/// What it does *not* know is whether it already has one. The folder import
/// copied each file in under a fresh UUID and discarded the original name, so
/// nothing on this Mac records where a file came from. That is why this
/// compares contents rather than names — see `reconcile` below.
public enum PiBridge {

    /// The Tailscale address, which is the one that works away from the house.
    /// `http://ceol-pi:8001` also appears in the Pi's own notes and only
    /// resolves on the local network; this is the one to default to.
    public static let defaultAddress = "https://ceol-pi.tail01672f.ts.net:8443"

    public static let addressKey = "ceol.pi.address"
    /// The username is remembered; the password never is. Nothing here writes
    /// to the Keychain, and a password in `UserDefaults` would be worse than
    /// typing it again on the handful of occasions this gets used.
    public static let userKey = "ceol.pi.username"

    /// Tolerate what someone would actually type: no scheme, a trailing slash.
    public static func base(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    public static func fileURL(_ name: String, at base: URL) -> URL {
        base.appendingPathComponent("api")
            .appendingPathComponent("uploads")
            .appendingPathComponent(name)
    }

    // MARK: - Getting in

    public enum Reachability: Sendable, Equatable {
        /// Answering, and this session is signed in.
        case ready
        /// Answering, but the session cookie is missing or expired.
        case needsSignIn
        /// Nothing there. Usually Tailscale being off.
        case unreachable(String)
    }

    /// Ask for a file that cannot exist, on the exact path the fetch will use.
    ///
    /// **404 is the good answer.** It means the request got past the login
    /// middleware and reached `serve_upload`, which looked for the name and did
    /// not find it — so a real name would be served. 401 means it never got
    /// that far.
    ///
    /// Probing the front page instead proves nothing: the middleware answers an
    /// unauthenticated browser with a redirect to `/login`, which `URLSession`
    /// follows, which returns 200. That is precisely how a session that could
    /// not read a single file looked like a healthy one, and why the first run
    /// reported everything fine and then failed 630 times.
    public static func check(_ base: URL) async -> Reachability {
        var request = URLRequest(url: fileURL("__fonn_probe__", at: base))
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("That address answered, but not as a web server.")
            }
            return (http.statusCode == 401 || http.statusCode == 403) ? .needsSignIn : .ready
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Sign in, so `URLSession` picks up the session cookie for later requests.
    ///
    /// Nothing is stored here. The Pi sets `__Host-ceol_session`, which
    /// `HTTPCookieStorage` keeps for as long as the app is running, and every
    /// later request to the same host carries it without being asked.
    /// Returns nil on success, or something to show you.
    public static func signIn(user: String, password: String, at base: URL) async -> String? {
        var request = URLRequest(url: base.appendingPathComponent("api/auth/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["username": user, "password": password])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "The Pi gave no answer." }
            if http.statusCode == 200 { return nil }
            // The Pi rate-limits by IP and says how long for; passing its own
            // message through is better than inventing one that omits that.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["error"] as? String ?? json["detail"] as? String {
                return message
            }
            return http.statusCode == 401
                ? "That username or password wasn't accepted."
                : "The Pi answered \(http.statusCode)."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - What is missing

    /// One file the Pi has and this Mac may not.
    public struct Want: Identifiable, Hashable, Sendable {
        public let id: String
        public let filename: String
        public let tuneTitle: String
        public let tune: PersistentIdentifier

        init(filename: String, tuneTitle: String, tune: PersistentIdentifier) {
            self.id = "\(tune.hashValue)|\(filename)"
            self.filename = filename
            self.tuneTitle = tuneTitle
            self.tune = tune
        }
    }

    /// Files named in a tune's notes that this Mac does not hold under that
    /// name.
    ///
    /// "Under that name" is the weak part and it is deliberate: a file fetched
    /// by an earlier run is stored as its Pi name and skipped here for nothing,
    /// but one brought in by the folder import carries a UUID and will be asked
    /// for again. `fetch` sorts that out by comparing contents once, and after
    /// that first pass the name test is enough.
    @MainActor
    public static func wanted(in context: ModelContext) -> [Want] {
        let tunes = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        var out: [Want] = []
        var seen = Set<String>()
        for tune in tunes {
            let named = LinkedText.uploadedFilenames(in: tune.notes)
            guard !named.isEmpty else { continue }
            let held = Set((tune.media ?? []).map(\.filename).filter { !$0.isEmpty })
            for name in named where !held.contains(name) {
                let want = Want(filename: name,
                                tuneTitle: tune.title,
                                tune: tune.persistentModelID)
                if seen.insert(want.id).inserted { out.append(want) }
            }
        }
        return out.sorted { $0.tuneTitle.localizedCaseInsensitiveCompare($1.tuneTitle) == .orderedAscending }
    }

    // MARK: - Fetching

    public struct Report: Sendable {
        /// Downloaded and attached: genuinely new.
        public var added = 0
        /// Downloaded, recognised as a file already attached to this tune under
        /// a UUID name, and renamed to match. Costs one download, once.
        public var matched = 0
        /// The Pi answered 404 — named in the notes, not on the server.
        public var notOnPi = 0
        /// Network trouble, or the file would not save.
        public var failed = 0
        public var failures: [String] = []
        /// The session went. Stop rather than reporting the same 401 six
        /// hundred times, which is what the first run did — a wall of
        /// identical failures that said nothing except, once, why.
        public var signedOut = false

        public var total: Int { added + matched + notOnPi + failed }

        public var summary: String {
            if signedOut { return "Signed out of the Pi before it could finish. Sign in and try again." }
            var parts: [String] = []
            if added > 0 { parts.append("\(added) new recording\(added == 1 ? "" : "s")") }
            if matched > 0 { parts.append("\(matched) already here") }
            if notOnPi > 0 { parts.append("\(notOnPi) not on the Pi") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.isEmpty ? "Nothing to fetch." : parts.joined(separator: ", ") + "."
        }
    }

    /// Fetch each wanted file and attach it.
    ///
    /// Deliberately one at a time. Downloading twenty at once would be faster
    /// and would also hammer a Raspberry Pi over a VPN for no benefit you would
    /// notice, and the progress figure stops meaning anything.
    @MainActor
    public static func fetch(_ wants: [Want],
                             from base: URL,
                             in context: ModelContext,
                             progress: @escaping (Int, Int) -> Void = { _, _ in },
                             isCancelled: @escaping () -> Bool = { false }) async -> Report {
        var report = Report()
        var done = 0
        progress(0, wants.count)

        for want in wants {
            // Stopping is checked here rather than where it is discovered: the
            // 401 below sits inside a `do` block, and an unlabelled `break`
            // there is a puzzle for whoever reads it next.
            if isCancelled() || report.signedOut { break }
            defer { done += 1; progress(done, wants.count) }

            guard let tune = context.model(for: want.tune) as? Tune else {
                report.failed += 1
                report.failures.append("\(want.filename) — its tune is no longer in the library")
                continue
            }

            var request = URLRequest(url: fileURL(want.filename, at: base))
            request.timeoutInterval = 60
            let data: Data
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    switch http.statusCode {
                    case 404:
                        report.notOnPi += 1
                    case 401, 403:
                        // No point asking 629 more times.
                        report.signedOut = true
                    default:
                        report.failed += 1
                        report.failures.append("\(want.filename) — the Pi answered \(http.statusCode)")
                    }
                    // The loop's own guard stops the next iteration.
                    continue
                }
                data = body
            } catch {
                report.failed += 1
                report.failures.append("\(want.filename) — \(error.localizedDescription)")
                continue
            }

            // Give SwiftUI a moment between files, so the progress bar moves and
            // the window stays alive. The import learned this the hard way.
            await Task.yield()

            if reconcile(data: data, named: want.filename, on: tune) {
                report.matched += 1
                continue
            }

            do {
                let stored = try MediaStore.shared.save(data, as: want.filename)
                let item = MediaItem(kind: MediaStore.kind(forExtension: (want.filename as NSString).pathExtension),
                                     title: (want.filename as NSString).deletingPathExtension,
                                     filename: stored)
                item.tune = tune
                context.insert(item)
                tune.updatedAt = Date()
                report.added += 1
            } catch {
                report.failed += 1
                report.failures.append("\(want.filename) — \(error.localizedDescription)")
            }
        }

        try? context.save()
        return report
    }

    /// Is this the same file the tune already has under a different name?
    ///
    /// The folder import named everything with a fresh UUID, so a tune can hold
    /// the very bytes now being downloaded and there is no way to tell from the
    /// record. Compare fingerprints; if one matches, rename that attachment to
    /// the Pi's name and keep the file that is already here.
    ///
    /// Renaming rather than leaving it alone is the point. Once the file is
    /// called what the Pi calls it, `wanted` stops asking for it, and the whole
    /// library converges on names that mean the same thing on every device —
    /// which is what a shared iCloud media folder will need.
    @MainActor
    private static func reconcile(data: Data, named name: String, on tune: Tune) -> Bool {
        let incoming = MediaStore.fingerprint(data)
        for item in tune.media ?? [] where !item.filename.isEmpty {
            guard MediaStore.shared.fingerprint(item.filename) == incoming else { continue }
            if MediaStore.shared.rename(item.filename, to: name) {
                item.filename = name
            }
            // Either way the tune has this recording, so nothing is added.
            return true
        }
        return false
    }
}
