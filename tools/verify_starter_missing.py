#!/usr/bin/env python3
"""Mirror of StarterLibrary.onlyMissing / missingCount
(Sources/CeolCore/Import/StarterLibrary.swift), run against the real starter
file and against the cases in Tests/CeolCoreTests/StarterMissingTests.swift.

There is no Swift toolchain where this was written, so this does not prove the
Swift compiles. It proves the rules: which starter tunes count as already
here, and how the set and the collection are cut down to match. Keep it in
step with StarterLibrary.swift.

    python3 CeolCore/tools/verify_starter_missing.py
"""
import json, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
SEED = os.path.join(HERE, "..", "Sources", "CeolCore", "Seed", "starter-library.json")

def key(t): return t.strip().lower()

def shipped_keys(j): return [key(t.get("title", "")) for t in j.get("tunes", []) if "title" in t]

def missing_count(j, present_titles):
    present = {key(t) for t in present_titles}
    return len([k for k in shipped_keys(j) if k not in present])

def only_missing(j, present):
    tunes = [t for t in j.get("tunes", []) if key(t.get("title", "")) not in present]
    kept = {t["id"] for t in tunes if isinstance(t.get("id"), int)}
    new_index, sets = {}, []
    for i, s in enumerate(j.get("sets", [])):
        wanted = [e["tune_id"] for e in s.get("entries", []) if isinstance(e.get("tune_id"), int)]
        if not wanted or not all(w in kept for w in wanted): continue
        new_index[i] = len(sets); sets.append(s)
    cols = []
    for c in j.get("collections", []):
        c = dict(c)
        ids = [i for i in c.get("tune_ids", []) if i in kept]
        idx = [new_index[i] for i in c.get("set_indexes", []) if i in new_index]
        if not ids and not idx: continue
        c["tune_ids"] = ids
        if "set_indexes" in c: c["set_indexes"] = idx
        cols.append(c)
    out = dict(j); out["tunes"] = tunes; out["sets"] = sets; out["collections"] = cols
    return out

failures = 0
def check(ok, label):
    global failures
    if not ok:
        failures += 1; print("FAIL:", label)

seed = json.load(open(SEED))
titles = [t["title"] for t in seed["tunes"]]
set_ids = [e["tune_id"] for e in seed["sets"][0]["entries"]]
set_titles = [t["title"] for t in seed["tunes"] if t["id"] in set_ids]
others = [t for t in titles if t not in set_titles]

check(len(titles) == 6, "six starter tunes")
check(len(set(map(key, titles))) == 6, "titles distinct when compared")

# Empty library: everything comes back.
out = only_missing(seed, set())
check(missing_count(seed, []) == 6, "empty: six missing")
check(len(out["tunes"]) == 6 and len(out["sets"]) == 1 and len(out["collections"]) == 1, "empty: all of it")
check(out["collections"][0]["tune_ids"] == seed["collections"][0]["tune_ids"], "empty: collection intact")

# All present, however they are spelt: nothing at all.
present = {key("  " + t.upper() + " ") for t in titles}
out = only_missing(seed, present)
check(missing_count(seed, [t.upper() for t in titles]) == 0, "all present: none missing")
check(out["tunes"] == [] and out["sets"] == [] and out["collections"] == [], "all present: nothing made")

# A set tune deleted, the rest kept: that tune returns, the half-set does not.
gone = set_titles[0]
present = {key(t) for t in titles if t != gone}
out = only_missing(seed, present)
check([t["title"] for t in out["tunes"]] == [gone], "one gone: only it returns")
check(out["sets"] == [], "one gone: no half set")
check(len(out["collections"]) == 1 and len(out["collections"][0]["tune_ids"]) == 1, "one gone: filed alone")

# Both set tunes gone: the set comes back with them.
present = {key(t) for t in others}
out = only_missing(seed, present)
check(len(out["tunes"]) == 2 and len(out["sets"]) == 1, "set tunes gone: set returns")

# An edited starter tune (same title, different notation) is not missing.
check(missing_count(seed, titles) == 0, "edited tune still counts as present")

# The cut never touches the original.
before = json.dumps(seed, sort_keys=True)
only_missing(seed, {key(titles[0])})
check(json.dumps(seed, sort_keys=True) == before, "input left alone")

# set_indexes, when a collection has them, are renumbered or dropped.
j = {"tunes": [{"id": 1, "title": "A"}, {"id": 2, "title": "B"}],
     "sets": [{"name": "S1", "entries": [{"tune_id": 1}]}, {"name": "S2", "entries": [{"tune_id": 2}]}],
     "collections": [{"name": "C", "tune_ids": [1, 2], "set_indexes": [0, 1]}]}
out = only_missing(j, {"a"})
check([s["name"] for s in out["sets"]] == ["S2"], "indexes: S2 kept")
check(out["collections"][0]["set_indexes"] == [0], "indexes: renumbered")

print("verify_starter_missing: all checks passed" if failures == 0 else f"verify_starter_missing: {failures} failed")
sys.exit(1 if failures else 0)
