#!/usr/bin/env python3
"""Mirror of SetListFilter.matches (Sources/CeolCore/Models/SetFilter.swift,
FONN-SETFILTER-1), against the cases in Tests/CeolCoreTests/SetFilterTests.swift.

    python3 CeolCore/tools/verify_set_filter.py
"""
import sys

def has(kinds, s):
    want = (lambda m: True) if kinds is None else (lambda m: m["kind"] in kinds)
    if any(want(m) for m in s.get("media", [])): return True
    return any(any(want(m) for m in t.get("media", [])) for t in s["tunes"])

def content_matches(c, s):
    tunes = s["tunes"]
    return {
        "any": lambda: True,
        "allNotation": lambda: bool(tunes) and all(t["notation"] for t in tunes),
        "someNoNotation": lambda: any(not t["notation"] for t in tunes),
        "anyMedia": lambda: has(None, s),
        "audio": lambda: has({"audio"}, s),
        "video": lambda: has({"video"}, s),
        "images": lambda: has({"photo", "pdf"}, s),
        "links": lambda: has({"link"}, s),
    }[c]()

def matches(f, s):
    if f.get("favourites") and not s.get("fav"): return False
    if f.get("hitlist") and not s.get("hit"): return False
    if f.get("minRating", 0) > 0 and s.get("rating", 0) < f["minRating"]: return False
    ic = f.get("inCollection", "any")
    if ic == "inCollection" and not s.get("collections"): return False
    if ic == "notInCollection" and s.get("collections"): return False
    if f.get("type") and not any(t["type"].lower() == f["type"].lower() for t in s["tunes"]): return False
    if f.get("key") and not any(t["key"] == f["key"] for t in s["tunes"]): return False
    return content_matches(f.get("content", "any"), s)

def chip(type_):
    t = type_.lower()
    return f"Has {'an' if t[:1] in 'aeiou' else 'a'} {t}"

def tune(type_, key, notation=True, media=()):
    return {"type": type_, "key": key, "notation": notation, "media": [{"kind": k} for k in media]}

fails = 0
def check(label, got, want):
    global fails
    ok = got == want
    if not ok: fails += 1
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"  got {got!r} want {want!r}"))

reels = {"tunes": [tune("reel", "D"), tune("reel", "G")]}
mixed = {"tunes": [tune("jig", "D"), tune("reel", "A")]}
jigs = {"tunes": [tune("jig", "G")]}
check("type: reels", matches({"type": "reel"}, reels), True)
check("type: mixed", matches({"type": "reel"}, mixed), True)
check("type: jigs", matches({"type": "reel"}, jigs), False)
s = {"tunes": [tune("reel", "D")], "rating": 3}
check("rating 4", matches({"minRating": 4}, s), False)
check("rating 3", matches({"minRating": 3}, s), True)
check("hitlist", matches({"minRating": 3, "hitlist": True}, s), False)
check("audio none", matches({"content": "audio"}, {"tunes": [tune("reel", "D")]}), False)
check("audio on tune", matches({"content": "audio"}, {"tunes": [tune("reel", "D", media=["audio"])]}), True)
check("audio on set", matches({"content": "audio"}, {"tunes": [tune("reel", "D")], "media": [{"kind": "audio"}]}), True)
check("all notation, empty set", matches({"content": "allNotation"}, {"tunes": []}), False)
check("some without", matches({"content": "someNoNotation"}, {"tunes": [tune("reel", "D"), tune("air", "G", notation=False)]}), True)
check("key", matches({"key": "A"}, mixed), True)
check("not in collection", matches({"inCollection": "notInCollection"}, {"tunes": [], "collections": ["x"]}), False)
check("chip air", chip("Air"), "Has an air")
check("chip reel", chip("reel"), "Has a reel")
print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
