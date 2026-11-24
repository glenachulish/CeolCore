"""python3 tools/build_starter_fonn.py

FONN-STARTERSETS-1. Takes the "Starter Sets — X" collection shares Callum
saved into ~/Apple Apps/Fonn/Collections to share/Starter sets/ and writes the
copies the app carries, into Sources/CeolCore/Seed/StarterSets/.

Only the music travels: each tune keeps its title, type, key, mode, ABC,
aliases, composer, transcriber and source address. Links, recordings, PDFs,
notes, ratings and anything else personal are dropped. Then it checks that
every set names tunes the file holds, and that every tune has notation, and
says what it found. Nothing is written for a file that fails.
"""
import json, os, sys, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.expanduser("~/Apple Apps/Fonn/Collections to share/Starter sets")
if not os.path.isdir(SRC):  # the same folder, seen from Claude's shell
    SRC = os.path.join(HERE, "../../Collections to share/Starter sets")
DST = os.path.join(HERE, "../Sources/CeolCore/Seed/StarterSets")
KEEP = ["title", "type", "key", "mode", "abc", "aliases", "composer",
        "transcribed_by", "source_url", "session_id", "setting_id"]

def norm(t): return unicodedata.normalize("NFC", (t or "").strip().lower())

def main():
    os.makedirs(DST, exist_ok=True)
    files = sorted(f for f in os.listdir(SRC) if f.endswith((".fonn", ".json")))
    if not files: sys.exit("No .fonn files in " + SRC)
    bad = 0
    for f in files:
        j = json.load(open(os.path.join(SRC, f), encoding="utf-8"))
        name = j.get("name", "")
        problems = []
        if j.get("type") != "collection": problems.append("not a collection share")
        if not name.startswith("Starter Sets"): problems.append("name is " + repr(name))
        tunes = []
        for t in j.get("tunes", []):
            tunes.append({k: t[k] for k in KEEP if t.get(k) not in (None, "", [])})
            if not (t.get("abc") or "").strip(): problems.append("no notation: " + t.get("title", "?"))
        titles = {norm(t["title"]) for t in tunes}
        sets = []
        for sd in j.get("sets", []):
            entries = sd.get("tunes", [])
            names = [e if isinstance(e, str) else e.get("title", "") for e in entries]
            missing = [n for n in names if norm(n) not in titles]
            if missing: problems.append(f"set {sd.get('name')!r} names tunes not in the file: {missing}")
            keep = {"name": sd.get("name", ""), "tunes": entries}
            if sd.get("notes"): pass  # personal; not carried
            sets.append(keep)
        out = {"ceol": 1, "type": "collection", "name": name,
               "description": j.get("description", ""), "tunes": tunes, "sets": sets}
        if problems:
            bad += 1
            print(f"✗ {f}:"); [print("   ", p) for p in problems]
            continue
        dest = os.path.join(DST, name.replace("/", "-") + ".fonn")
        json.dump(out, open(dest, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"✓ {name}: {len(sets)} sets, {len(tunes)} tunes, {os.path.getsize(dest)//1024} KB")
    if bad: sys.exit(f"{bad} file(s) not carried; see above")

main()
