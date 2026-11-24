#!/usr/bin/env python3
"""Mirror of LibraryDates.parse / earlier (FONN-ADDEDDATE-1).

No Swift toolchain where this was written: this proves the rules, not that the
Swift compiles. Keep it in step with Sources/CeolCore/Import/LibraryDates.swift.
Run with paths to .ceol.json files to see how many dates each one restores."""
import sys, json
from datetime import datetime, timezone, timedelta

EARLIEST = datetime(2000, 1, 1, tzinfo=timezone.utc)

def parse(raw, now=None):
    now = now or datetime.now(timezone.utc)
    if not isinstance(raw, str) or not raw.strip(): return None
    s = raw.strip(); d = None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):          # ISO 8601
        try: d = datetime.strptime(s, fmt).replace(tzinfo=timezone.utc); break
        except ValueError: pass
    if d is None:
        try:
            if "T" in s and (s.endswith("Z") or "+" in s[10:] or s[19:20] == "-"):
                d = datetime.fromisoformat(s.replace("Z", "+00:00"))
        except ValueError: pass
    if d is None:
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
            try: d = datetime.strptime(s, fmt).replace(tzinfo=timezone.utc); break
            except ValueError: pass
    if d is None: return None
    if d > now + timedelta(days=1) or d < EARLIEST: return None
    return d

def earlier(current, raw):
    d = parse(raw)
    return d if d and d < current else current

now = datetime(2026, 11, 24, tzinfo=timezone.utc)
cases = [
    ("2026-09-01T12:34:56Z", datetime(2026, 9, 1, 12, 34, 56, tzinfo=timezone.utc)),
    ("2026-09-01T12:34:56.123Z", datetime(2026, 9, 1, 12, 34, 56, 123000, tzinfo=timezone.utc)),
    ("2026-08-01 07:05:00", datetime(2026, 8, 1, 7, 5, tzinfo=timezone.utc)),
    ("2026-08-01", datetime(2026, 8, 1, tzinfo=timezone.utc)),
    (None, None), ("", None), ("  ", None), ("yesterday", None), (12345, None),
    ("2031-01-01T00:00:00Z", None), ("1970-01-01 00:00:00", None),
]
bad = 0
for raw, want in cases:
    got = parse(raw, now)
    if got != want: bad += 1; print("FAIL", repr(raw), got, want)
cur = datetime(2026, 11, 20, tzinfo=timezone.utc)
assert earlier(cur, "2026-09-01T00:00:00Z") < cur, "earlier should move back"
assert earlier(cur, "2026-11-22T00:00:00Z") == cur, "earlier must never move forward"
assert earlier(cur, None) == cur
print(f"{len(cases) - bad}/{len(cases)} parse cases pass; earlier() rules pass")

for path in sys.argv[1:]:
    j = json.load(open(path))
    tunes = j.get("tunes", []); sets = j.get("sets", [])
    t_ok = sum(1 for t in tunes if parse(t.get("imported_at")))
    s_ok = sum(1 for s in sets if parse(s.get("created_at")))
    raws = [t.get("imported_at") for t in tunes if t.get("imported_at") and not parse(t.get("imported_at"))]
    print(f"{path.split('/')[-1]}: tunes {t_ok}/{len(tunes)} dated, sets {s_ok}/{len(sets)} dated"
          + (f"; unreadable e.g. {raws[:2]}" if raws else ""))
sys.exit(1 if bad else 0)
