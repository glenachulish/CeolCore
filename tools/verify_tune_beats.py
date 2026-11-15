"""FONN-ABCFOLLOW-1: checks TuneBeats.grid (CeolCore/Audio/TuneBeats.swift).

The fixtures are the bar lists abc.html / set.html build (ceolBarsFromTimings)
from the bundled abcjs's own timings: a reel with a pickup and endings, a jig
whose pickup comes back after a short bar, and a jig-into-reel set. "One" must
land on every full bar, the pickup must count as the end of a bar.
Run: python3 tools/verify_tune_beats.py
"""
import json
# Python transliteration of TuneBeats.grid (CeolCore/Audio/TuneBeats.swift)
def grid(bars, end, clicks):
    def nxt(i): return bars[i+1][0] if i+1 < len(bars) else max(end, bars[i][0]+bars[i][1])
    def isfull(i): return i < len(bars) and nxt(i)-bars[i][0] > bars[i][1]*0.9
    T=[];P=[];carry=None
    for i,b in enumerate(bars):
        n=max(1,clicks(b)); L=b[1]/n; e=nxt(i)
        fit=min(n,max(0,int(round((e-b[0])/L))))
        if fit==0: continue
        if fit==n:
            for j in range(n): T.append(b[0]+j*L); P.append(j)
            carry=None
        elif carry is not None and carry+fit<=n:
            for j in range(fit): T.append(b[0]+j*L); P.append(carry+j)
            carry = carry+fit if carry+fit<n else None
        elif isfull(i+1) and (i==0 or fit*2<=n):
            for j in range(fit): T.append(e-(fit-j)*L); P.append(n-fit+j)
            carry=None
        else:
            for j in range(fit): T.append(b[0]+j*L); P.append(j)
            carry=fit
    return T,P

FIXTURES = json.loads("{\"reel\": {\"bars\": [[0, 1333.375, 2, 1], [333, 1333.375, 2, 1], [1667, 1333.375, 2, 1], [3000, 1333.375, 2, 1], [4333, 1333.375, 2, 1], [5667, 1333.375, 2, 1], [7000, 1333.375, 2, 1], [8333, 1333.375, 2, 1], [9667, 1333.375, 2, 1]], \"end\": 11000}, \"jig\": {\"bars\": [[0, 1200, 2, 3], [200, 1200, 2, 3], [1400, 1200, 2, 3], [2400, 1200, 2, 3], [2600, 1200, 2, 3], [3800, 1200, 2, 3], [4800, 1200, 2, 3], [5000, 1200, 2, 3], [6200, 1200, 2, 3], [7200, 1200, 2, 3], [7400, 1200, 2, 3], [8600, 1200, 2, 3]], \"end\": 9600}, \"set\": {\"bars\": [[0, 1200, 2, 3], [200, 1200, 2, 3], [1400, 1200, 2, 3], [2400, 1200, 2, 3], [2600, 1200, 2, 3], [3800, 1200, 2, 3], [4800, 1333.5, 2, 1], [5133, 1333.5, 2, 1], [6467, 1333.5, 2, 1], [7800, 1333.5, 2, 1], [9133, 1333.5, 2, 1]], \"end\": 10467}}")
EXPECTED_ONES = {'reel': [333, 1667, 3000, 4333, 5667, 7000, 8333, 9667], 'jig': [200, 1400, 2600, 3800, 5000, 6200, 7400, 8600], 'set': [200, 1400, 2600, 3800, 5133, 6467, 7800, 9133]}

ok = True
for name, v in FIXTURES.items():
    bars = [[x[0]/1000, x[1]/1000, x[2], x[3]] for x in v["bars"]]
    for mode, clicks in [("counted", lambda b: b[2]*b[3]), ("main", lambda b: b[2])]:
        T, P = grid(bars, v["end"]/1000, clicks)
        ones = [round(t*1000) for t, p in zip(T, P) if p == 0]
        good = ones == EXPECTED_ONES[name]
        ok &= good
        print(("OK  " if good else "FAIL"), name, mode, ones)
if name and FIXTURES["jig"]:
    T, P = grid([[x[0]/1000, x[1]/1000, x[2], x[3]] for x in FIXTURES["jig"]["bars"]], FIXTURES["jig"]["end"]/1000, lambda b: b[2]*b[3])
    pick = [(round(t*1000), p) for t, p in zip(T, P) if round(t*1000) in (0, 2400)]
    good = pick == [(0, 5), (2400, 5)]
    ok &= good
    print(("OK  " if good else "FAIL"), "jig pickups count as six", pick)
raise SystemExit(0 if ok else 1)
