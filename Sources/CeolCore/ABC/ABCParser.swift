import Foundation

/// Minimal ABC header parsing — enough to fill in tune metadata on import.
public enum ABCParser {

    public struct ParsedTune {
        public var title = ""
        public var type = ""
        public var key = ""
        public var mode = ""
        public var composer = ""
        public var abc = ""
        public var aliases: [String] = []

        public init() {}
    }

    /// Split a multi-tune ABC file into individual tunes (X: headers).
    public static func splitTunes(_ text: String) -> [String] {
        var tunes: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("X:") {
                if current.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("X:") }) {
                    tunes.append(current.joined(separator: "\n"))
                    current = []
                }
            }
            current.append(line)
        }
        let last = current.joined(separator: "\n")
        if !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tunes.append(last)
        }
        return tunes
    }

    public static func parse(_ abc: String) -> ParsedTune {
        var result = ParsedTune()
        result.abc = abc.trimmingCharacters(in: .whitespacesAndNewlines)

        var titles: [String] = []
        for line in abc.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == ":" else { continue }
            let field = trimmed.prefix(1)
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            switch field {
            case "T": titles.append(value)
            case "R": if result.type.isEmpty { result.type = value.lowercased() }
            case "C": if result.composer.isEmpty { result.composer = value }
            case "K":
                if result.key.isEmpty {
                    let (key, mode) = parseKeyField(value)
                    result.key = key
                    result.mode = mode
                }
            default: break
            }
        }
        result.title = titles.first ?? "Untitled"
        result.aliases = Array(titles.dropFirst())
        return result
    }

    /// "Ador" → ("A", "dorian"); "D" → ("D", "major"); "Gm" → ("G", "minor")
    public static func parseKeyField(_ raw: String) -> (key: String, mode: String) {
        let value = raw.components(separatedBy: .whitespaces).first ?? raw
        guard !value.isEmpty else { return ("", "") }

        var idx = value.startIndex
        var key = String(value[idx]).uppercased()
        idx = value.index(after: idx)
        if idx < value.endIndex, value[idx] == "#" || value[idx] == "b" {
            key += String(value[idx])
            idx = value.index(after: idx)
        }
        let rest = String(value[idx...]).lowercased()

        let modes: [(prefix: String, name: String)] = [
            ("maj", "major"), ("min", "minor"), ("m", "minor"),
            ("dor", "dorian"), ("phr", "phrygian"), ("lyd", "lydian"),
            ("mix", "mixolydian"), ("aeo", "aeolian"), ("loc", "locrian"),
            ("ion", "major"),
        ]
        for m in modes where rest.hasPrefix(m.prefix) {
            return (key, m.name)
        }
        return (key, rest.isEmpty ? "major" : rest)
    }
}
