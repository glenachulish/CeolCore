#!/usr/bin/env python3
"""Mirror of the shared-file rules (FONN-SHARE-1, FONN-LOOPSYNC-1):
LibraryExport.shareEntry (what travels) and FileImports.attachShared (what is
added at the other end), plus MediaItem.savedLoop. Round-trips a sample tune.
Keep in step with the Swift.

    python3 CeolCore/tools/verify_share_file.py
"""
import base64, json, sys

def saved_loop(item):
    a, b = item.get("loopStart", -1), item.get("loopEnd", -1)
    return (a, b) if a >= 0 and b > a else None

def share_entry(item, files):
    k = item["kind"]
    if k == "link":
        if not item.get("url"): return None
        m = {"kind": "link", "url": item["url"]}
        if item.get("title"): m["title"] = item["title"]
        loop = saved_loop(item)
        if loop: m["loop_start"], m["loop_end"] = loop
        return m
    if k == "pdf":
        data = files.get(item.get("filename"))
        if data is None: return None
        m = {"kind": "pdf", "data": base64.b64encode(data).decode(), "filename": item["filename"]}
        if item.get("title"): m["title"] = item["title"]
        return m
    return None

def attach_shared(entries, have):
    added = 0
    for e in entries or []:
        k, title = e.get("kind", ""), e.get("title", "")
        if k == "link":
            url = (e.get("url") or "").strip()
            if not url or any(h.get("url") == url for h in have): continue
            item = {"kind": "link", "title": title, "url": url, "loopStart": -1, "loopEnd": -1}
            a, b = e.get("loop_start"), e.get("loop_end")
            if isinstance(a, (int, float)) and isinstance(b, (int, float)) and b > a and a >= 0:
                item["loopStart"], item["loopEnd"] = a, b
            have.append(item); added += 1
        elif k == "pdf":
            try: data = base64.b64decode(e.get("data") or "", validate=True)
            except Exception: continue
            if not data: continue
            name = title or e.get("filename", "")
            if any(h["kind"] == "pdf" and name and (h.get("title") == name or h.get("filename") == name) for h in have): continue
            have.append({"kind": "pdf", "title": name, "filename": "new.pdf"}); added += 1
    return added

fails = 0
def check(label, got, want):
    global fails
    ok = got == want
    if not ok: fails += 1
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"\n   got  {got!r}\n   want {want!r}"))

files = {"a.pdf": b"%PDF-1.4 sample"}
mine = [
    {"kind": "link", "url": "https://music.apple.com/gb/album/x/1?i=2", "title": "The Kesh — Lùnasa", "loopStart": 12.5, "loopEnd": 20.25},
    {"kind": "link", "url": "https://youtu.be/abc", "title": ""},
    {"kind": "audio", "filename": "rec.m4a"},
    {"kind": "video", "filename": "v.mov"},
    {"kind": "pdf", "filename": "a.pdf", "title": "Book page"},
    {"kind": "pdf", "filename": "missing.pdf"},
]
entries = [e for e in (share_entry(i, files) for i in mine) if e]
check("only links and present PDFs travel", [e["kind"] for e in entries], ["link", "link", "pdf"])
check("loop travels", (entries[0].get("loop_start"), entries[0].get("loop_end")), (12.5, 20.25))
check("no loop key when none", "loop_start" in entries[1], False)
wire = json.loads(json.dumps({"media": entries}))

theirs = []
check("all three attach to a fresh tune", attach_shared(wire["media"], theirs), 3)
check("loop arrives", saved_loop(theirs[0]), (12.5, 20.25))
check("title arrives", theirs[0]["title"], "The Kesh — Lùnasa")
check("second import adds nothing", attach_shared(wire["media"], theirs), 0)
check("bad loop ignored", saved_loop([{"kind": "link"}][0] | {"loopStart": 5, "loopEnd": 3}), None)
bad = [{"kind": "link", "url": "https://x.org", "loop_start": 9, "loop_end": 4},
       {"kind": "audio", "filename": "r.m4a"}, {"kind": "pdf", "data": "!!notbase64"}]
h = []
check("bad entries: only the link, without its loop", (attach_shared(bad, h), saved_loop(h[0])), (1, None))
print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
