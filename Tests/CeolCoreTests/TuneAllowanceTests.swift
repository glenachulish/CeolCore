import Testing
import Foundation
@testable import CeolCore

/// The free version's allowance.
///
/// Each test builds its own `TuneAllowance` over in-memory storage, so none of
/// them touches the real Keychain or the real preferences, and none can see
/// another's count. (`TuneAllowance.shared` is deliberately not used here: in a
/// test run it starts unlocked, so the importers' own tests are not capped.)
struct TuneAllowanceTests {

    private func allowance(layers: Int = 3,
                           startingAt counts: [Int] = []) -> (TuneAllowance, [MemoryLayer]) {
        let stores = (0..<layers).map { _ in MemoryLayer() }
        for (index, count) in counts.enumerated() where index < stores.count {
            stores[index].write(count)
        }
        let suite = "ceol.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (TuneAllowance(layers: stores, defaults: defaults), stores)
    }

    @Test("twenty additions are admitted and the twenty-first is not")
    func stopsAtTheLimit() {
        let (a, _) = allowance()
        for _ in 0..<TuneAllowance.freeLimit { #expect(a.admit()) }
        #expect(!a.admit())
        #expect(a.used == TuneAllowance.freeLimit)
        #expect(a.isAtLimit)
    }

    @Test("a refusal does not move the count")
    func refusalLeavesCountAlone() {
        let (a, _) = allowance(startingAt: [TuneAllowance.freeLimit])
        #expect(!a.admit())
        #expect(!a.admit())
        #expect(a.used == TuneAllowance.freeLimit)
        #expect(a.takeRefusals() == 2)
        #expect(a.takeRefusals() == 0)
    }

    @Test("a bulk request is granted in part, up to what is left")
    func bulkIsPartial() {
        let (a, _) = allowance(startingAt: [15])
        #expect(a.admit(wanting: 50) == 5)
        #expect(a.used == 20)
        #expect(a.admit(wanting: 3) == 0)
        #expect(a.takeRefusals() == 45 + 3)
    }

    @Test("the largest stored count wins, so a reinstall cannot reset it")
    func largestLayerWins() {
        // Preferences wiped by a reinstall; the Keychain copy survived.
        let (a, layers) = allowance(startingAt: [0, 18, 0])
        #expect(a.used == 18)
        #expect(a.remaining == 2)
        // And the layers that had lost it are brought back up to date.
        #expect(layers.map { $0.read() } == [18, 18, 18])
    }

    @Test("every layer is written on each addition")
    func writesEverywhere() {
        let (a, layers) = allowance()
        _ = a.admit(wanting: 4)
        #expect(layers.map { $0.read() } == [4, 4, 4])
    }

    @Test("refresh picks up a higher count written by another device")
    func refreshSeesOtherDevices() {
        let (a, layers) = allowance()
        _ = a.admit(wanting: 3)
        layers[1].write(19)
        a.refresh()
        #expect(a.used == 19)
        #expect(a.remaining == 1)
    }

    @Test("refresh never lowers the count")
    func refreshNeverLowers() {
        let (a, layers) = allowance()
        _ = a.admit(wanting: 10)
        for layer in layers { layer.write(2) }
        a.refresh()
        #expect(a.used == 10)
    }

    @Test("unlocked, everything is admitted and nothing is counted")
    func unlockedIsUnlimited() {
        let (a, _) = allowance(startingAt: [TuneAllowance.freeLimit])
        a.setUnlocked(true)
        #expect(a.admit(wanting: 500) == 500)
        #expect(a.used == TuneAllowance.freeLimit)
        #expect(a.remaining == Int.max)
    }

    @Test("locking again restores the limit")
    func relocking() {
        let (a, _) = allowance(startingAt: [TuneAllowance.freeLimit])
        a.setUnlocked(true)
        a.setUnlocked(false)
        #expect(!a.admit())
    }

    @Test("uncounted work is neither counted nor refused, even at the limit")
    func uncountedBlock() {
        let (a, _) = allowance(startingAt: [TuneAllowance.freeLimit])
        let granted = a.uncounted { a.admit(wanting: 6) }
        #expect(granted == 6)
        #expect(a.used == TuneAllowance.freeLimit)
        #expect(!a.admit())   // the block ended, so the limit is back
    }

    @Test("asking for nothing grants nothing and costs nothing")
    func zeroAndNegative() {
        let (a, _) = allowance()
        #expect(a.admit(wanting: 0) == 0)
        #expect(a.admit(wanting: -3) == 0)
        #expect(a.used == 0)
    }
}
