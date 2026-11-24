"""python3 tools/build_starter_from_export.py <library.ceol.json>

FONN-STARTERSETS-1. Builds the starter-set files the app carries straight
from a whole-library export, so the eight "Starter Sets — X" collections
needn't be shared one by one. For each collection whose name starts
"Starter Sets", writes Sources/CeolCore/Seed/StarterSets/<name>.fonn in the
same shape as a collection share: the collection's tunes plus every tune its
sets use, and the sets with their tunes in order (title, key and mode, so the
right version is picked).

Only the music travels: title, type, key, mode, ABC, aliases, composer,
transcriber, source address. Links, recordings, PDFs, notes, ratings and set
notes are left behind. A collection with a tune without notation, or a set
naming a tune it can't find, is reported and not written.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DST = os.path.join(HERE, "../Sources/CeolCore/Seed/StarterSets")
KEEP = ["title", "type", "key", "mode", "abc", "aliases", "composer",
        "transcribed_by", "source_url", "session_id", "setting_id"]

def main(path, prefix="Starter Sets"):
    lib = json.load(open(path, encoding="utf-8"))
    tunes = {t["id"]: t for t in lib.get("tunes", []) if "id" in t}
    sets = lib.get("sets", [])
    wanted = [c for c in lib.get("collections", []) if c.get("name", "").startswith(prefix)]
    if not wanted:
        sys.exit(f"No collection whose name starts {prefix!r} in {path}")
    os.makedirs(DST, exist_ok=True)
    bad = 0
    for c in sorted(wanted, key=lambda c: c["name"]):
        problems, ids = [], []
        def take(tid):
            if tid not in tunes: problems.append(f"tune id {tid} not in the export"); return None
            if tid not in ids: ids.append(tid)
            return tunes[tid]
        out_sets = []
        for si in c.get("set_indexes", []):
            if si >= len(sets): problems.append(f"set index {si} missing"); continue
            sd = sets[si]
            entries = []
            for e in sorted(sd.get("entries", []), key=lambda e: e.get("position", 0)):
                t = take(e.get("tune_id"))
                if t: entries.append({"title": t["title"], "key": t.get("key", ""), "mode": t.get("mode", ""),
                                      "_position": len(entries)})
            out_sets.append({"name": sd.get("name", ""), "tunes": entries})
        for tid in c.get("tune_ids", []): take(tid)
        out_tunes = []
        for tid in ids:
            t = tunes[tid]
            if not (t.get("abc") or "").strip(): problems.append("no notation: " + t["title"])
            out_tunes.append({k: t[k] for k in KEEP if t.get(k) not in (None, "", [])})
        name = c["name"]
        if problems:
            bad += 1
            print(f"✗ {name}:"); [print("   ", p) for p in problems]; continue
        doc = {"ceol": 1, "type": "collection", "name": name,
               "description": c.get("description", ""), "tunes": out_tunes, "sets": out_sets}
        dest = os.path.join(DST, name.replace("/", "-") + ".fonn")
        json.dump(doc, open(dest, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"✓ {name}: {len(out_sets)} sets, {len(out_tunes)} tunes, {os.path.getsize(dest)//1024} KB")
    if bad: sys.exit(f"{bad} collection(s) not written; see above")

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    main(sys.argv[1], *(sys.argv[2:3]))
