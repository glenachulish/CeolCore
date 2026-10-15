import Foundation
import Security

/// The free version's allowance: how many tunes it will let you add, and the
/// memory of how many you already have.
///
/// ## What is counted
///
/// **Additions, not the size of the library.** The rule Fonn tells people is
/// "the free version lets you add 20 tunes", and deleting one does not give the
/// room back. Counting what is *currently in* the library would be simpler, but
/// it would make the limit a speed bump: delete one, add one, indefinitely.
///
/// Only a genuinely new tune is an addition. A second setting of a tune you
/// already have joins that tune's version group and is not counted — the
/// library shows one row per group, so to the person using it that is still
/// one tune. The six starter tunes are not counted either; see `uncounted`.
///
/// ## Where the count lives
///
/// A counter kept only in the app's own preferences resets the moment someone
/// deletes and reinstalls, which would make the limit meaningless. So the count
/// is written to three places and the *largest* value wins:
///
/// 1. `UserDefaults` — fast, and gone on reinstall.
/// 2. The Keychain, marked synchronisable — survives deleting the app, and
///    travels between a person's devices through iCloud Keychain.
/// 3. iCloud key-value storage — the same idea by another route. It needs the
///    key-value-store entitlement; without it the calls quietly do nothing and
///    the other two carry the count.
///
/// Taking the maximum is safe precisely because the count only ever goes up.
/// Two devices that each add a tune offline will converge on the larger of the
/// two numbers rather than the sum, which errs towards the person — the right
/// way round for a limit that is a nudge, not a lock.
///
/// ## Threading
///
/// Importers run on whichever thread they were started from, so everything here
/// is behind one lock and nothing is `@MainActor`. The lock is held only for
/// the arithmetic and the three small writes.
public final class TuneAllowance: @unchecked Sendable {

    public static let shared = TuneAllowance()

    /// What the free version allows. Also the number printed on the unlock
    /// screen and in the App Store description — change them together.
    public static let freeLimit = 20

    /// Posted on the main queue when an addition was refused. Coalesced: a bulk
    /// import that refuses fifty tunes posts once, so the unlock screen opens
    /// once rather than fifty times.
    public static let didRefuse = Notification.Name("CeolCore.TuneAllowance.didRefuse")

    /// Posted on the main queue when the count or the unlocked state changes.
    public static let didChange = Notification.Name("CeolCore.TuneAllowance.didChange")

    // MARK: - State

    private let lock = NSLock()
    private let layers: [any CounterLayer]
    private let defaults: UserDefaults

    private var count: Int
    private var unlocked: Bool
    private var uncountedDepth = 0
    private var refusals = 0
    private var refusalPosted = false

    private static let unlockedKey = "ceol.unlockedCache"

    public convenience init() {
        if Self.isRunningTests {
            // The package's own tests insert thousands of tunes through the
            // same importers the apps use. With the real allowance in the way
            // the twenty-first would be refused and every later test would
            // fail for a reason that has nothing to do with what it tests.
            // Nothing is written anywhere persistent, either: a test run must
            // not leave a count in the developer's Keychain.
            self.init(layers: [MemoryLayer()],
                      defaults: UserDefaults(suiteName: "ceol.tests.allowance") ?? .standard)
            setUnlocked(true)
        } else {
            self.init(layers: [DefaultsLayer(), KeychainLayer(), CloudLayer()],
                      defaults: .standard)
        }
    }

    /// Whether this process is a test run. Checked several ways because SwiftPM
    /// and Xcode, and XCTest and Swift Testing, each announce themselves
    /// differently and none of them promises to keep doing so.
    private static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil {
            return true
        }
        if NSClassFromString("XCTestCase") != nil { return true }
        let name = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? ""
        return name == "xctest" || name.hasPrefix("swiftpm-testing-helper")
    }

    init(layers: [any CounterLayer], defaults: UserDefaults) {
        self.layers = layers
        self.defaults = defaults
        // Last known answer from the previous launch. It is only a starting
        // point so a paying customer is not shown the limit for the second
        // it takes StoreKit to answer; `PurchaseStore` overwrites it.
        self.unlocked = defaults.bool(forKey: Self.unlockedKey)
        self.count = layers.map { $0.read() }.max() ?? 0
        // Bring the lagging layers up to the leader, so a reinstall that kept
        // only the Keychain copy re-seeds the others straight away.
        for layer in layers where layer.read() < count { layer.write(count) }

        if let cloud = layers.first(where: { $0 is CloudLayer }) as? CloudLayer {
            cloud.onExternalChange = { [weak self] in self?.refresh() }
        }
    }

    // MARK: - Reading

    /// Tunes added so far, ever. May exceed `freeLimit` after an import that
    /// was exactly on the line, never by more than the importer's own batch.
    public var used: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    public var remaining: Int {
        lock.lock(); defer { lock.unlock() }
        return unlocked ? Int.max : max(0, Self.freeLimit - count)
    }

    public var isUnlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return unlocked
    }

    public var isAtLimit: Bool { remaining == 0 }

    // MARK: - Asking

    /// Ask to add one new tune. Call immediately before inserting it, and
    /// insert only if this returns `true`.
    @discardableResult
    public func admit() -> Bool {
        admit(wanting: 1) == 1
    }

    /// Ask to add up to `wanting` tunes at once; returns how many are allowed.
    /// For callers that know the size of a batch up front.
    public func admit(wanting: Int) -> Int {
        guard wanting > 0 else { return 0 }
        lock.lock()
        if unlocked || uncountedDepth > 0 {
            lock.unlock()
            return wanting
        }
        let room = max(0, Self.freeLimit - count)
        let granted = min(room, wanting)
        if granted > 0 { persist(count + granted) }
        let refused = wanting - granted
        if refused > 0 { refusals += refused }
        let shouldPost = refused > 0 && !refusalPosted
        if shouldPost { refusalPosted = true }
        lock.unlock()

        if granted > 0 { postOnMain(Self.didChange) }
        if shouldPost {
            DispatchQueue.main.async { [weak self] in
                self?.lock.lock(); self?.refusalPosted = false; self?.lock.unlock()
                NotificationCenter.default.post(name: Self.didRefuse, object: nil)
            }
        }
        return granted
    }

    /// How many additions were refused since the last call, and reset to zero.
    /// Lets a screen say "12 tunes weren't added" after an import.
    public func takeRefusals() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = refusals
        refusals = 0
        return n
    }

    /// Run `body` with additions neither counted nor refused.
    ///
    /// For the starter tunes, which are the app's gift to a new reader and not
    /// something they added. Anything running concurrently on another thread is
    /// also let through while this is active, which is acceptable for a block
    /// that takes a fraction of a second at first launch.
    public func uncounted<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); uncountedDepth += 1; lock.unlock()
        defer { lock.lock(); uncountedDepth -= 1; lock.unlock() }
        return try body()
    }

    // MARK: - Unlock state

    /// Set by `PurchaseStore` once StoreKit has answered.
    public func setUnlocked(_ value: Bool) {
        lock.lock()
        let changed = unlocked != value
        unlocked = value
        defaults.set(value, forKey: Self.unlockedKey)
        lock.unlock()
        if changed { postOnMain(Self.didChange) }
    }

    /// Re-read the stored counts. Called when the app returns to the
    /// foreground, and when iCloud says another device has changed its copy.
    public func refresh() {
        lock.lock()
        let latest = layers.map { $0.read() }.max() ?? 0
        var changed = false
        if latest > count {
            count = latest
            changed = true
        }
        // Also brings back any layer that has fallen behind, which is how a
        // Keychain that was unavailable at launch catches up when it is not.
        for layer in layers where layer.read() < count { layer.write(count) }
        lock.unlock()
        if changed { postOnMain(Self.didChange) }
    }

    #if DEBUG
    /// Back to nothing added, for testing the limit over and over. Not
    /// compiled into release builds, so there is no way to call it for real.
    public func resetForTesting() { setUsedForTesting(0) }

    /// Pretend this many places are used, so the limit can be reached with one
    /// small import rather than twenty tunes. Debug builds only, for the same
    /// reason as the reset.
    public func setUsedForTesting(_ value: Int) {
        lock.lock()
        count = max(0, value)
        for layer in layers { layer.write(count) }
        lock.unlock()
        postOnMain(Self.didChange)
    }
    #endif

    // MARK: - Internals

    /// Caller holds the lock.
    private func persist(_ value: Int) {
        count = value
        for layer in layers { layer.write(value) }
    }

    private func postOnMain(_ name: Notification.Name) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: name, object: nil) }
    }
}

// MARK: - Storage layers

/// One place the count is kept. Reads return 0 when there is nothing or the
/// place is unavailable; writes fail silently. A layer that does not work must
/// never be the reason the app does not.
protocol CounterLayer: AnyObject {
    func read() -> Int
    func write(_ value: Int)
}

/// Holds the count in memory only. Used by tests, and by the test-run
/// instance of `TuneAllowance.shared`.
final class MemoryLayer: CounterLayer {
    private var value = 0
    func read() -> Int { value }
    func write(_ newValue: Int) { value = newValue }
}

final class DefaultsLayer: CounterLayer {
    private let key = "ceol.tunesAddedEver"
    func read() -> Int { UserDefaults.standard.integer(forKey: key) }
    func write(_ value: Int) { UserDefaults.standard.set(value, forKey: key) }
}

final class CloudLayer: CounterLayer {
    private let key = "ceol.tunesAddedEver"
    var onExternalChange: (() -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.onExternalChange?() }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func read() -> Int { Int(NSUbiquitousKeyValueStore.default.longLong(forKey: key)) }

    func write(_ value: Int) {
        NSUbiquitousKeyValueStore.default.set(Int64(value), forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

final class KeychainLayer: CounterLayer {
    private let service = "com.glenachulish.fonn.allowance"
    private let account = "tunes-added"

    /// `kSecAttrSynchronizableAny` matches the item whether or not it has
    /// synced, which is what a lookup wants; adding needs a concrete `true`.
    /// The data-protection keychain is what lets a *macOS* app use
    /// synchronisable items at all; iOS ignores the flag.
    private var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
         kSecUseDataProtectionKeychain as String: true]
    }

    func read() -> Int {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let text = String(data: data, encoding: .utf8),
              let value = Int(text) else { return 0 }
        return value
    }

    func write(_ value: Int) {
        let data = Data(String(value).utf8)
        let status = SecItemUpdate(match as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = match
        add[kSecAttrSynchronizable as String] = true
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
