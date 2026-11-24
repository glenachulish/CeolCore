import Foundation

/// FONN-ADDEDDATE-1: reading "when was this first added" back out of a
/// library file.
///
/// The export has always written each tune's `createdAt` as `imported_at`,
/// but the importer never read it, so restoring a library — or moving it to a
/// new phone or Mac — stamped every tune with the day of the restore, and
/// "Added" and Recently Added both went wrong.
///
/// Two writers, two shapes:
///   • Fonn (iOS / Mac / Android): ISO 8601, `2026-09-01T12:34:56Z`
///   • the Pi: SQLite's `CURRENT_TIMESTAMP`, `2026-08-01 12:34:56`, in UTC
/// Fractional seconds and a bare `2026-08-01` are accepted too. Anything else
/// (null, blank, nonsense, or a date in the future) gives nil, and the caller
/// keeps today — the same as before this existed.
public enum LibraryDates {

    public static func parse(_ raw: Any?) -> Date? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }
        guard let date = iso(text) ?? sqlite(text) else { return nil }
        // A clock set wrong on the device that wrote the file shouldn't put a
        // tune at the top of Recently Added for years. A day's grace covers
        // time zones.
        guard date <= Date.now.addingTimeInterval(86_400),
              date >= earliest else { return nil }
        return date
    }

    /// The earlier of the two, for healing a tune that is already in the
    /// library: a restore can only move "Added" back towards the truth, never
    /// forward past a date the library already had.
    public static func earlier(_ current: Date, _ fromFile: Any?) -> Date {
        guard let date = parse(fromFile), date < current else { return current }
        return date
    }

    // MARK: -

    private static let earliest = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01

    private static func iso(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func sqlite(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: text) { return d }
        }
        return nil
    }
}
