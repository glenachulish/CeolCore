import SwiftUI
import StoreKit

/// The unlock screen. One view for both platforms: the two apps differ in how
/// they present it (a sheet on both, in practice) but not in what it says.
///
/// What it says is the point. The limit is stated plainly and before anyone
/// pays: what is free, what happens at the limit, that nothing already in the
/// library is held back, and that the money is spent once.
public struct UnlockView: View {
    @ObservedObject private var store = PurchaseStore.shared
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fonn is free for \(TuneAllowance.freeLimit) tunes")
                        .font(.title2.bold())
                    Text(progressLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    point("music.note.list",
                          "The free version lets you add \(TuneAllowance.freeLimit) tunes. Deleting one doesn't free up a place.")
                    point("checkmark.circle",
                          "When you reach the limit, everything you've added stays and keeps working: playback, sets, practice tools, recordings. You just can't add more.")
                    point("infinity",
                          "Unlock Fonn once to add as many tunes as you like. It's a single payment, not a subscription, and it covers your iPhone, iPad and Mac.")
                    point("square.and.arrow.up",
                          "Your library is always yours. You can export all of it, whether or not you've unlocked.")
                }

                if store.isUnlocked {
                    Label("Fonn is unlocked. Thank you.", systemImage: "heart.fill")
                        .font(.headline)
                } else {
                    VStack(spacing: 10) {
                        Button {
                            Task { await store.buy() }
                        } label: {
                            Text(buyTitle).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(store.isWorking)

                        Button("Restore purchase") { Task { await store.restore() } }
                            .disabled(store.isWorking)

                        Button("Not now") { dismiss() }
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                if let message = store.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 440)
        #endif
        .overlay(alignment: .center) {
            if store.isWorking { ProgressView() }
        }
    }

    private var progressLine: String {
        if store.isUnlocked { return "No limit on tunes." }
        let used = min(store.tunesUsed, TuneAllowance.freeLimit)
        return "You've added \(used) of \(TuneAllowance.freeLimit)."
    }

    private var buyTitle: String {
        if let price = store.product?.displayPrice { return "Unlock Fonn · \(price)" }
        return "Unlock Fonn"
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A line for a Settings screen: where you stand, and a way in to the unlock
/// screen. Each app drops it into whatever its Settings are made of.
public struct UnlockStatusRow: View {
    @ObservedObject private var store = PurchaseStore.shared
    @State private var showing = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mainRow
            #if DEBUG
            Toggle("Behave as the free version (testing)", isOn: $forceDemo)
                .onChange(of: forceDemo) { _, _ in
                    PurchaseStore.shared.reapplyUnlockState()
                }
            Button("Reset the free-tune count (testing)") {
                TuneAllowance.shared.resetForTesting()
            }
            Button("Pretend \(TuneAllowance.freeLimit - 1) of \(TuneAllowance.freeLimit) are used (testing)") {
                TuneAllowance.shared.setUsedForTesting(TuneAllowance.freeLimit - 1)
            }
            #endif
        }
    }

    #if DEBUG
    @AppStorage(PurchaseStore.forceDemoKey) private var forceDemo = false
    #endif

    private var mainRow: some View {
        Button {
            showing = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isUnlocked ? "Fonn is unlocked" : "Unlock Fonn")
                    Text(store.isUnlocked
                         ? "No limit on tunes"
                         : "\(min(store.tunesUsed, TuneAllowance.freeLimit)) of \(TuneAllowance.freeLimit) free tunes added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) { UnlockView() }
    }
}

public extension View {
    /// Present the unlock screen whenever an addition is refused. Apply once,
    /// at the root of each app, so no individual importer has to know about it.
    func unlockSheet() -> some View {
        modifier(UnlockSheetModifier())
    }
}

private struct UnlockSheetModifier: ViewModifier {
    @ObservedObject private var store = PurchaseStore.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $store.showingUnlock) { UnlockView() }
    }
}
