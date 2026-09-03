import Foundation

/// The live line to CloudKit.
///
/// SwiftData's mirroring syncs without any of this — at launch, and
/// periodically after that. What it will not do on its own is tell the other
/// device *now*. That is what a silent push is for: CloudKit subscribes on the
/// app's behalf, APNs delivers a payload with no alert and no sound, and the
/// store pulls the change down. Nobody sees a notification. The tune has
/// simply changed by the time they look at it.
///
/// Three things have to be true, and every one of them fails quietly:
///
/// 1. the entitlement — `aps-environment` on iOS, `com.apple.developer.aps-environment`
///    on macOS. Two different spellings for the same capability, which is the
///    sort of detail that costs an evening;
/// 2. on iOS, `remote-notification` in `UIBackgroundModes`, or the push arrives
///    and the app is never woken to do anything about it;
/// 3. a call to `registerForRemoteNotifications()`. Without a device token
///    there is nowhere to send a push, and nothing anywhere says so.
///
/// This type covers the third, and records how it went so Settings can say.
///
/// ## No permission is asked for, deliberately
///
/// `registerForRemoteNotifications()` on its own is enough for silent pushes.
/// Asking through `UNUserNotificationCenter` would put a dialog in front of
/// somebody for a feature they will never see, and a proportion of them would
/// quite reasonably say no — turning off sync for a notification the app was
/// never going to send.
public enum CloudPush {

    private static let outcomeKey = "ceol.push.lastOutcome"

    /// APNs handed over a device token. Changes now arrive by themselves.
    public static func registered() {
        record("Live sync is on. Changes made on your other devices arrive here on their own.")
    }

    /// No token. Not fatal, and worth saying so in the same breath: the library
    /// still syncs, it just waits for the app to open.
    public static func failed(_ error: Error) {
        record("Live sync is off — \(error.localizedDescription) Your library still syncs whenever Fonn opens.")
    }

    /// Registration was deliberately not attempted, because this device is set
    /// to device-only storage. Clears rather than records: a stale "live sync
    /// is on" under a library that is no longer syncing would be worse than
    /// saying nothing.
    public static func notWanted() {
        UserDefaults.standard.removeObject(forKey: outcomeKey)
    }

    private static func record(_ text: String) {
        UserDefaults.standard.set(text, forKey: outcomeKey)
    }

    /// What happened last time, for the Settings screen. Nil before the app has
    /// tried — which on a first launch is the honest answer for a second or
    /// two, since APNs replies asynchronously.
    public static var lastOutcome: String? {
        UserDefaults.standard.string(forKey: outcomeKey)
    }
}
