import Foundation
import WebKit

/// Serves abcjs its instrument samples without needing the internet.
///
/// abcjs builds one URL per note — `<soundFontUrl><name>-mp3/<note>.mp3` — and
/// fetches it with XMLHttpRequest. Left to itself it fetches from a CDN, so a
/// session hall with no signal means no sound. Registering this handler for the
/// `ceolsf` scheme puts us in the middle of those requests, where each note is
/// answered from, in order:
///
///   1. the app bundle — the flute, whistle and fiddle samples carried over
///      from the Pi, which work on a plane or in a cellar;
///   2. the on-disk cache — anything played once before, while online;
///   3. the CDN — fetched, answered, and written to the cache so it is never
///      needed twice.
///
/// A note that can't be found anywhere gets a clean 404, which is what abcjs
/// expects for a pitch outside an instrument's range.
public final class SoundfontHandler: NSObject, WKURLSchemeHandler {

    /// Spelled out because the app builds one per web view, and NSObject's
    /// init does not come across a module boundary as public.
    public override init() { super.init() }

    public static let scheme = "ceolsf"

    /// Where abcjs would have gone. Matches the default it uses today, so
    /// anything not bundled sounds exactly as it does now.
    private static let cdn = "https://paulrosen.github.io/midi-js-soundfonts/FluidR3_GM/"

    /// abcjs derives the folder name from the MIDI program, so two instruments
    /// that share a program share a name. Concert Flute and Irish Flute are
    /// both program 73; the voice baked into the URL breaks the tie.
    private static let voiceOverrides: [String: (abcName: String, folder: String)] = [
        "mflute": (abcName: "flute", folder: "mflute"),
    ]


    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Soundfont", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The base URL to hand abcjs for a given instrument voice.
    static func fontURL(voice: String) -> String {
        "\(scheme)://ceol/\(voice)/"
    }

    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let request = Self.parse(url) else {
            task.didFailWithError(Self.notFound); return
        }

        if let data = Self.bundled(request) ?? Self.cached(request) {
            Self.answer(task, with: data, url: url)
            return
        }

        // Not in the bundle or the cache — ask the CDN, for any instrument.
        //
        // Bundled instruments used to refuse this, so that a note outside the
        // flute's range couldn't be filled in with a synthesised one. That was
        // the wrong trade by a long way: abcjs loads its samples with
        // `Promise.all` and swallows the rejection, so a single unanswered
        // note doesn't lose one note — it loses the whole tune, silently.
        // A slightly different timbre on one note at the top of the range is
        // nothing beside that.
        let folder = Self.cdnFolder(for: request)
        guard let remote = URL(string: Self.cdn + "\(folder)-mp3/\(request.note).mp3") else {
            Self.answer(task, notFoundFor: url); return
        }
        let dataTask = URLSession.shared.dataTask(with: remote) { [weak self] data, response, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // The task is dead once the web view has moved on; touching it
                // then is a crash, so check we still own it.
                guard self.tasks.removeValue(forKey: ObjectIdentifier(task)) != nil else { return }
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                if ok, let data, !data.isEmpty {
                    Self.store(data, for: request)
                    Self.answer(task, with: data, url: url)
                } else {
                    Self.answer(task, notFoundFor: url)
                }
            }
        }
        tasks[ObjectIdentifier(task)] = dataTask
        dataTask.resume()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    // MARK: - Resolving a request

    private struct Request {
        /// The instrument folder to serve from, after the voice override.
        let folder: String
        let note: String
    }

    /// Instrument folders the CDN actually has. Anything else — most often the
    /// literal string "undefined" — is a name abcjs invented, and asking for it
    /// can only 404.
    ///
    /// abcjs takes the folder name from the MIDI program in the tune's own ABC.
    /// A tune carrying `%%MIDI program 71` asks for clarinet samples; one whose
    /// program falls outside abcjs's table asks for `undefined-mp3/E5.mp3`.
    /// Thirteen tunes in four hundred do this. It matters far more than it
    /// sounds, because abcjs loads a batch with `Promise.all` and swallows the
    /// rejection — so one unanswerable note silences the entire tune, and
    /// reports no error at all.
    private static let knownInstruments: Set<String> = [
        "flute", "whistle", "violin", "accordion", "banjo", "orchestral_harp",
        "acoustic_grand_piano", "acoustic_guitar_nylon", "acoustic_guitar_steel",
        "recorder", "piccolo", "clarinet", "oboe", "bassoon", "pan_flute",
        "fiddle", "mandolin", "cello", "viola", "contrabass", "harmonica",
        "bagpipe", "shanai", "tuba", "trumpet", "trombone", "french_horn",
        "electric_guitar_clean", "electric_guitar_jazz", "acoustic_bass",
        "celesta", "vibraphone", "marimba", "xylophone", "church_organ",
        "reed_organ", "rock_organ", "drawbar_organ", "soprano_sax", "alto_sax",
        "tenor_sax", "baritone_sax", "dulcimer", "kalimba", "ocarina",
    ]

    /// `ceolsf://ceol/<voice>/<abcName>-mp3/<note>.mp3`
    private static func parse(_ url: URL) -> Request? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 3,
              parts[1].hasSuffix("-mp3"),
              parts[2].hasSuffix(".mp3") else { return nil }
        let voice = parts[0]
        let abcName = String(parts[1].dropLast(4))
        let note = String(parts[2].dropLast(4))
        // Notes are named like "D5" or "Db5" — nothing else may reach the disk.
        guard note.range(of: "^[A-G]b?[0-8]$", options: .regularExpression) != nil
        else { return nil }

        // A name we can't serve is answered with the instrument the player is
        // actually set to, rather than refused. The Pi learned this the same
        // way and does the same thing: better the chosen instrument than
        // silence.
        guard knownInstruments.contains(abcName) else {
            return Request(folder: folder(forVoice: voice), note: note)
        }

        // Only the melody instrument is affected by the voice; chords keep
        // their own name and their own samples.
        if let override = voiceOverrides[voice], override.abcName == abcName {
            return Request(folder: override.folder, note: note)
        }
        return Request(folder: abcName, note: note)
    }

    private static func folder(forVoice voice: String) -> String {
        if let override = voiceOverrides[voice] { return override.folder }
        return knownInstruments.contains(voice) ? voice : "flute"
    }

    /// What to ask the CDN for. The two flutes we carry are not names it has —
    /// "mflute" is our own, and Eskin's "flute" is a different recording of a
    /// real one — so both fall back to general MIDI's flute.
    private static func cdnFolder(for request: Request) -> String {
        switch request.folder {
        case "mflute": return "flute"
        case "whistle": return "whistle"
        default: return request.folder
        }
    }

    private static func bundled(_ request: Request) -> Data? {
        guard let url = CeolResources.soundfont(folder: request.folder,
                                                note: request.note) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func cacheURL(_ request: Request) -> URL {
        cacheDirectory.appendingPathComponent("\(request.folder)-\(request.note).mp3")
    }

    private static func cached(_ request: Request) -> Data? {
        try? Data(contentsOf: cacheURL(request))
    }

    private static func store(_ data: Data, for request: Request) {
        try? data.write(to: cacheURL(request), options: .atomic)
    }

    // MARK: - Answering

    private static let notFound = NSError(domain: NSURLErrorDomain,
                                          code: NSURLErrorFileDoesNotExist)

    private static func answer(_ task: WKURLSchemeTask, with data: Data, url: URL) {
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg",
                           "Content-Length": String(data.count),
                           "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// abcjs checks for status 200 and shrugs off anything else, which is how a
    /// note outside an instrument's range is meant to be handled.
    private static func answer(_ task: WKURLSchemeTask, notFoundFor url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: 404,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didFinish()
    }

    // MARK: - Filling the cache on purpose

    /// Every note in the standard soundfont range, in the naming the sample
    /// files use (flats, no sharps).
    static let allNotes: [String] = {
        let names = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
        var notes: [String] = ["A0", "Bb0", "B0"]
        for octave in 1...7 { notes += names.map { "\($0)\(octave)" } }
        notes.append("C8")
        return notes
    }()

    /// How much has been downloaded so far, in bytes.
    public static func cachedBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    public static func emptyCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Pull down every note of the given instruments so they work offline too.
    /// Notes already bundled or cached are skipped, so running this twice is
    /// quick and running it after a part-finished attempt picks up where it
    /// stopped.
    public static func download(instruments: [String],
                         progress: @escaping (Int, Int) -> Void) async {
        let wanted = instruments.flatMap { folder in
            allNotes.map { Request(folder: folder, note: $0) }
        }.filter { bundled($0) == nil && cached($0) == nil }

        let total = wanted.count
        guard total > 0 else { await MainActor.run { progress(0, 0) }; return }

        var done = 0
        // Six at a time: enough to keep a phone's connection busy without
        // opening 700 sockets at once.
        await withTaskGroup(of: (Request, Data?).self) { group in
            var next = 0
            func submit() {
                guard next < wanted.count else { return }
                let request = wanted[next]; next += 1
                group.addTask {
                    guard let url = URL(string: cdn + "\(request.folder)-mp3/\(request.note).mp3"),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200
                    else { return (request, nil) }
                    return (request, data)
                }
            }
            for _ in 0..<min(6, wanted.count) { submit() }
            for await (request, data) in group {
                if let data, !data.isEmpty { store(data, for: request) }
                done += 1
                let snapshot = done
                await MainActor.run { progress(snapshot, total) }
                submit()
            }
        }
    }
}
