#!/usr/bin/env python3
"""Mirror of TuneAllowance's rules, run against the same cases as
Tests/CeolCoreTests/TuneAllowanceTests.swift.

There is no Swift toolchain where this was written, so this does not prove the
Swift compiles. It proves the *rules* are what the tests say they are: that the
arithmetic of admit / bulk / merge-by-maximum / refresh / uncounted gives the
answers the tests expect. Keep it in step with TuneAllowance.swift."""

LIMIT = 20

class Layer:
    def __init__(self, v=0): self.v = v
    def read(self): return self.v
    def write(self, n): self.v = n

class Allowance:
    def __init__(self, layers):
        self.layers = layers
        self.unlocked = False
        self.depth = 0
        self.refusals = 0
        self.count = max((l.read() for l in layers), default=0)
        for l in layers:
            if l.read() < self.count: l.write(self.count)

    @property
    def used(self): return self.count
    @property
    def remaining(self): return float('inf') if self.unlocked else max(0, LIMIT - self.count)

    def admit(self, wanting=1):
        if wanting <= 0: return 0
        if self.unlocked or self.depth > 0: return wanting
        room = max(0, LIMIT - self.count)
        granted = min(room, wanting)
        if granted > 0:
            self.count += granted
            for l in self.layers: l.write(self.count)
        self.refusals += wanting - granted
        return granted

    def take_refusals(self):
        n, self.refusals = self.refusals, 0
        return n

    def uncounted(self, body):
        self.depth += 1
        try: return body()
        finally: self.depth -= 1

    def refresh(self):
        latest = max((l.read() for l in self.layers), default=0)
        if latest > self.count: self.count = latest
        for l in self.layers:
            if l.read() < self.count: l.write(self.count)

def make(starting=()):
    layers = [Layer() for _ in range(3)]
    for i, c in enumerate(starting): layers[i].write(c)
    return Allowance(layers), layers

def check(name, cond):
    print(('PASS  ' if cond else 'FAIL  ') + name)
    if not cond: check.failed += 1
check.failed = 0

# stopsAtTheLimit
a, _ = make()
check("twenty admitted", all(a.admit() == 1 for _ in range(LIMIT)))
check("twenty-first refused", a.admit() == 0)
check("used == limit and at limit", a.used == LIMIT and a.remaining == 0)

# refusalLeavesCountAlone
a, _ = make([LIMIT])
a.admit(); a.admit()
check("refusal leaves count", a.used == LIMIT)
check("refusals counted then reset", a.take_refusals() == 2 and a.take_refusals() == 0)

# bulkIsPartial
a, _ = make([15])
check("bulk partial: 5 of 50", a.admit(50) == 5 and a.used == 20)
check("then none", a.admit(3) == 0)
check("refusals 45 + 3", a.take_refusals() == 48)

# largestLayerWins
a, layers = make([0, 18, 0])
check("largest layer wins", a.used == 18 and a.remaining == 2)
check("laggards brought up", [l.read() for l in layers] == [18, 18, 18])

# writesEverywhere
a, layers = make(); a.admit(4)
check("written to every layer", [l.read() for l in layers] == [4, 4, 4])

# refreshSeesOtherDevices
a, layers = make(); a.admit(3); layers[1].write(19); a.refresh()
check("refresh sees 19", a.used == 19 and a.remaining == 1)

# refreshNeverLowers
a, layers = make(); a.admit(10)
for l in layers: l.write(2)
a.refresh()
check("refresh never lowers", a.used == 10)
check("refresh repairs lagging layers", [l.read() for l in layers] == [10, 10, 10])

# unlockedIsUnlimited
a, _ = make([LIMIT]); a.unlocked = True
check("unlocked admits 500, counts nothing", a.admit(500) == 500 and a.used == LIMIT)

# relocking
a, _ = make([LIMIT]); a.unlocked = True; a.unlocked = False
check("relocked refuses", a.admit() == 0)

# uncountedBlock
a, _ = make([LIMIT])
granted = a.uncounted(lambda: a.admit(6))
check("uncounted passes at the limit", granted == 6 and a.used == LIMIT)
check("limit is back after the block", a.admit() == 0)

# zeroAndNegative
a, _ = make()
check("zero and negative", a.admit(0) == 0 and a.admit(-3) == 0 and a.used == 0)

# release-order scenario from the design: delete never gives room back
a, _ = make(); a.admit(20)
check("deleting a tune does not free a place (count is additions, not size)", a.admit() == 0)

# grandfathering rule
import datetime as dt
CUT = dt.datetime(2026, 10, 5, tzinfo=dt.timezone.utc).timestamp()
def grandfathers(ts, production): return production and ts < CUT
check("paid era, production: grandfathered", grandfathers(1_790_000_000, True))
check("free era, production: not", not grandfathers(1_792_000_000, True))
check("sandbox never trusted", not grandfathers(1_790_000_000, False) and not grandfathers(0, False))
check("cut-over constant matches Swift (1791158400)", CUT == 1_791_158_400)

import sys
print("\n%s" % ("ALL PASS" if not check.failed else f"{check.failed} FAILED"))
sys.exit(1 if check.failed else 0)
