import Foundation

/// The version and build the app is running, as one line: "1.2 (7)".
///
/// Both numbers, because TestFlight lists builds by number and two builds of
/// 1.2 look the same without it. Shown at the top of Settings on the phone and
/// in the Mac's Settings window.
public enum AppVersion {
    public static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
