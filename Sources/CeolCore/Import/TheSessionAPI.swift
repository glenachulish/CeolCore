import Foundation

/// Client for thesession.org's public JSON API.
/// Mirrors the import pipeline of the Ceòl web app (v3 backend):
/// type-based meter/note-length, AABB repeat reconstruction, key
/// normalisation, aliases, votes and member credits.
public enum TheSessionAPI {

    /// Meter and default note-length for each TheSession tune type
    /// (port of v3's _TYPE_METER map).
    public static let typeMeter: [String: (meter: String, noteLength: String)] = [
        "reel":       ("4/4",  "1/8"),
        "jig":        ("6/8",  "1/8"),
        "slip jig":   ("9/8",  "1/8"),
        "hornpipe":   ("4/4",  "1/8"),
        "polka":      ("2/4",  "1/8"),
        "waltz":      ("3/4",  "1/4"),
        "strathspey": ("4/4",  "1/8"),
        "mazurka":    ("3/4",  "1/8"),
        "barndance":  ("4/4",  "1/8"),
        "march":      ("4/4",  "1/8"),
        "slide":      ("12/8", "1/8"),
    ]

    public struct SearchResult: Identifiable, Hashable {
        public let id: Int
        public let name: String
        public let type: String
        public let tunebooks: Int
    }

    public struct Setting: Identifiable, Hashable {
        public let id: Int
        public let index: Int          // 1-based position, matches thesession.org display
        public let key: String         // normalised key letter, e.g. "D"
        public let mode: String        // normalised mode, e.g. "dorian"
        public let abc: String         // complete ABC document, ready to render
        public let member: String
        public let votes: Int
        public let date: String

        public var displayKey: String {
            let m = mode.lowercased()
            if m.isEmpty || m == "major" { return key }
            return key + String(m.prefix(3))
        }
    }

    public struct TuneDetail {
        public let id: Int
        public let name: String
        public let type: String
        public let aliases: [String]
        public let settings: [Setting]
    }

    public enum APIError: LocalizedError {
        case badResponse
        case noSettings
        public var errorDescription: String? {
            switch self {
            case .badResponse: return "thesession.org returned an unexpected response."
            case .noSettings: return "No ABC settings found for this tune."
            }
        }
    }

    private static func request(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Ceol-iOS/1.0 trad-music-app", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        return json
    }

    public static func search(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://thesession.org/tunes/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "perpage", value: "30"),
        ]
        let json = try await request(components.url!)
        guard let tunes = json["tunes"] as? [[String: Any]] else { throw APIError.badResponse }
        return tunes.compactMap { t in
            guard let id = t["id"] as? Int, let name = t["name"] as? String else { return nil }
            return SearchResult(id: id, name: name,
                                type: t["type"] as? String ?? "",
                                tunebooks: t["tunebooks"] as? Int ?? 0)
        }
    }

    public static func tune(id: Int) async throws -> TuneDetail {
        let json = try await request(URL(string: "https://thesession.org/tunes/\(id)?format=json")!)
        guard let name = json["name"] as? String else { throw APIError.badResponse }
        let rawSettings = (json["settings"] as? [[String: Any]]) ?? []
        guard !rawSettings.isEmpty else { throw APIError.noSettings }

        let type = (json["type"] as? String ?? "").lowercased()
        let tuneMeter = json["meter"] as? String ?? ""

        // Aliases arrive either as plain strings or {name: ...} objects.
        let aliases: [String] = ((json["aliases"] as? [Any]) ?? []).compactMap {
            if let s = $0 as? String { return s }
            if let d = $0 as? [String: Any] { return d["name"] as? String }
            return nil
        }

        let settings: [Setting] = rawSettings.enumerated().compactMap { i, s in
            guard let sid = s["id"] as? Int, let body = s["abc"] as? String else { return nil }
            let rawKey = s["key"] as? String ?? ""
            let (keyNorm, modeNorm) = ABCParser.parseKeyField(rawKey)
            let meter = (s["meter"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tuneMeter
            let fullABC = buildABC(index: i + 1, title: name, type: type,
                                   rawKey: rawKey, body: body, meter: meter)
            let member = (s["member"] as? [String: Any])?["name"] as? String ?? ""
            return Setting(id: sid, index: i + 1,
                           key: keyNorm, mode: modeNorm,
                           abc: addSessionRepeats(fullABC),
                           member: member,
                           votes: s["votes"] as? Int ?? 0,
                           date: s["date"] as? String ?? "")
        }
        return TuneDetail(id: id, name: name, type: type, aliases: aliases, settings: settings)
    }

    /// Reconstruct a full ABC document from TheSession API fields
    /// (port of v3's _build_session_abc).
    public static func buildABC(index: Int, title: String, type: String,
                         rawKey: String, body: String, meter: String) -> String {
        let defaults = typeMeter[type] ?? ("4/4", "1/8")
        let finalMeter = meter.isEmpty ? defaults.meter : meter
        var lines = ["X: \(index)", "T: \(title)"]
        if !type.isEmpty { lines.append("R: \(type)") }
        lines.append("M: \(finalMeter)")
        lines.append("L: \(defaults.noteLength)")
        lines.append("K: \(rawKey)")
        let cleanBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n" + cleanBody
    }

    /// Add |: :| repeat barlines to TheSession ABC if missing
    /// (port of v3's _add_session_repeats). TheSession stores ABC without
    /// explicit repeats and their player adds AABB repeats by convention.
    public static func addSessionRepeats(_ abc: String) -> String {
        guard let kRange = abc.range(of: #"(?m)^K:[^\n]*\n"#, options: .regularExpression) else {
            return abc
        }
        let header = String(abc[abc.startIndex..<kRange.upperBound])
        let body = String(abc[kRange.upperBound...])

        // Already has repeat marks — leave untouched
        if body.contains("|:") || body.contains(":|") { return abc }

        let parts = body.components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return abc }

        return header + "|:" + parts.joined(separator: ":||:") + ":|"
    }
}
