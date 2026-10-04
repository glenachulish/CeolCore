import Combine
import Foundation
import StoreKit
import SwiftUI

/// The one-time purchase that turns the free version into the full one.
///
/// StoreKit 2, one non-consumable product, no subscription. It is the same
/// product on iPhone, iPad and Mac because both apps share a bundle id, so
/// buying on one unlocks the other.
///
/// This class decides *whether the person is unlocked* and hands the answer to
/// `TuneAllowance`, which is what the importers actually ask. Keeping the two
/// apart means an importer running on a background thread never touches
/// StoreKit or the main actor.
///
/// There are four ways to be unlocked, and they are deliberately separate:
///
/// 1. **You bought it** — a verified, unrevoked transaction for the product.
/// 2. **You bought Fonn before it became free** — see `grandfathers`.
/// 3. **You are running a build that did not come from Apple** — Xcode, or the
///    Mac app installed by script. These are the developer's own copies, and
///    capping them would only get in the way of testing the thing being built.
/// 4. Nothing else. Not TestFlight, and not App Review, which must both see
///    the real limit and the real purchase sheet.
@MainActor
public final class PurchaseStore: ObservableObject {

    public static let shared = PurchaseStore()

    /// Must match the product created in App Store Connect, and `Fonn.storekit`.
    public static let productID = "com.glenachulish.fonn.unlock"

    /// Anyone whose *original* download predates this was a paying customer of
    /// the earlier, paid-upfront Fonn and keeps the full app. The app was taken
    /// off sale on 4 October 2026 with no recorded sales, so in practice this
    /// protects gifted copies and anything not yet reported. It is cheap
    /// insurance, and it is much harder to put in afterwards.
    nonisolated static let paidEraEnds = Date(timeIntervalSince1970: 1_791_158_400) // 2026-10-05T00:00:00Z

    /// Set in Settings (debug builds) to see the free version on a developer
    /// build, which would otherwise be unlocked. Without this the limit could
    /// only ever be tested through TestFlight.
    public static let forceDemoKey = "ceol.forceDemo"

    /// Whether an original download counts as a purchase of the earlier paid
    /// Fonn. Only believed in the production environment; see
    /// `checkOriginalPurchase`. Pulled out as a plain function so the rule can
    /// be tested without StoreKit.
    nonisolated static func grandfathers(originalPurchaseDate: Date,
                                         isProduction: Bool) -> Bool {
        isProduction && originalPurchaseDate < paidEraEnds
    }

    // MARK: - What the interface reads

    @Published public private(set) var product: Product?
    @Published public private(set) var purchased = false
    @Published public private(set) var isWorking = false
    @Published public var message: String?
    @Published public var showingUnlock = false

    /// Used and remaining, republished so views refresh as tunes are added.
    @Published public private(set) var tunesUsed = TuneAllowance.shared.used

    public var tunesLeft: Int { max(0, TuneAllowance.freeLimit - tunesUsed) }

    public var isUnlocked: Bool { purchased || grandfathered || developerBuild }

    public private(set) var grandfathered = false

    /// Positive answers are remembered between launches, so that a customer
    /// who is offline — or simply early, before StoreKit has answered — is not
    /// shown the limit. Only a definite "no" clears them: a refund, or a
    /// production App Store record that says the first download was recent.
    /// Wrongly unlocking costs one sale; wrongly locking a buyer costs a
    /// customer.
    private static let purchasedCacheKey = "ceol.purchasedCache"
    private static let grandfatheredCacheKey = "ceol.grandfatheredCache"

    private init() {
        purchased = UserDefaults.standard.bool(forKey: Self.purchasedCacheKey)
        grandfathered = UserDefaults.standard.bool(forKey: Self.grandfatheredCacheKey)
    }

    /// True when this copy of the app did not come from the App Store or
    /// TestFlight. Both of those leave a receipt in the bundle; a build run
    /// from Xcode, or one copied into /Applications by a script, does not.
    public var developerBuild: Bool {
        if UserDefaults.standard.bool(forKey: Self.forceDemoKey) { return false }
        guard let url = Bundle.main.appStoreReceiptURL else { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    private var updates: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Starting

    /// Call once, at launch, from each app. Safe to call again.
    public func start() {
        guard updates == nil else { return }

        // Purchases that complete outside the app — approved by a parent after
        // "Ask to Buy", redeemed with a code, or bought on another device —
        // arrive here, not through `purchase()`.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: TuneAllowance.didRefuse, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showingUnlock = true }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: TuneAllowance.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tunesUsed = TuneAllowance.shared.used }
        })

        applyUnlockState()
        Task {
            await refreshPurchases()
            await checkOriginalPurchase()
            await loadProduct()
        }
    }

    // MARK: - Actions

    public func buy() async {
        guard let product else {
            message = "The store isn't available just now. Please try again in a moment."
            await loadProduct()
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
                if isUnlocked { showingUnlock = false }
            case .pending:
                // Ask to Buy, or a payment that needs further approval.
                message = "Waiting for approval. Fonn will unlock as soon as it comes through."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through: \(error.localizedDescription)"
        }
    }

    /// Required by App Review: a way to get the unlock back on a new device or
    /// after reinstalling, without paying twice.
    public func restore() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppStore.sync()
            await refreshPurchases()
            if isUnlocked {
                message = "Your purchase has been restored."
                showingUnlock = false
            } else {
                message = "There's no earlier purchase of Fonn on this Apple Account."
            }
        } catch {
            // Cancelling the Apple Account sign-in prompt lands here too, and
            // is not worth an error message.
            if case .userCancelled? = error as? StoreKitError {
                // Nothing to say.
            } else {
                message = "Couldn't reach the App Store: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - StoreKit plumbing

    private func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            product = nil
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result,
              transaction.productID == Self.productID else { return }
        purchased = transaction.revocationDate == nil
        UserDefaults.standard.set(purchased, forKey: Self.purchasedCacheKey)
        applyUnlockState()
        await transaction.finish()
    }

    private func refreshPurchases() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        // An empty answer is not the same as "refunded": offline, or before
        // the account has synced, it can simply be empty. So a remembered yes
        // stands unless a revoked transaction for this product turns up.
        var refunded = false
        if !owned && purchased {
            for await result in Transaction.all {
                if case .verified(let transaction) = result,
                   transaction.productID == Self.productID,
                   transaction.revocationDate != nil {
                    refunded = true
                }
            }
        }
        if owned {
            purchased = true
        } else if refunded || !purchased {
            purchased = false
        }
        UserDefaults.standard.set(purchased, forKey: Self.purchasedCacheKey)
        applyUnlockState()
    }

    /// Was this Apple Account one of the people who paid for Fonn before it was
    /// free? Only believed in the production environment: TestFlight and App
    /// Review report a made-up original version and date, and trusting them
    /// would hand reviewers the full app and leave them nothing to test.
    private func checkOriginalPurchase() async {
        do {
            let result = try await AppTransaction.shared
            guard case .verified(let app) = result,
                  app.environment == .production else { return }
            grandfathered = Self.grandfathers(originalPurchaseDate: app.originalPurchaseDate,
                                              isProduction: true)
            UserDefaults.standard.set(grandfathered, forKey: Self.grandfatheredCacheKey)
            applyUnlockState()
        } catch {
            // Offline, or not an App Store install. Stay as we were; this runs
            // again at the next launch.
        }
    }

    private func applyUnlockState() {
        TuneAllowance.shared.setUnlocked(isUnlocked)
        tunesUsed = TuneAllowance.shared.used
        objectWillChange.send()
    }

    /// Push the current answer to `TuneAllowance` again. For the testing
    /// switches in Settings, which change the answer without a purchase.
    public func reapplyUnlockState() { applyUnlockState() }
}
