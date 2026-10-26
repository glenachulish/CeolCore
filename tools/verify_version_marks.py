"""Mirror of VersionTools' marks rules (26 Oct 2026), run without Swift.

Stars, hitlist and heart belong to the tune: they live on the group's default,
travel with makeDefault / delete / group, and are copied onto new versions.
"""
import uuid

class Tune:
    def __init__(s, name, rating=0, hit=False, fav=False, group=None, default=True):
        s.name, s.rating, s.onHitlist, s.isFavourite = name, rating, hit, fav
        s.groupID, s.isDefaultVersion = group, default

LIB = []
def versions(t): return [t] if t.groupID is None else [x for x in LIB if x.groupID == t.groupID]
def shown(t):
    if t.groupID is None or t.isDefaultVersion: return t
    return next((x for x in versions(t) if x.isDefaultVersion), t)
marksHolder = shown
def carryMarks(src, dst): dst.rating, dst.onHitlist, dst.isFavourite = src.rating, src.onHitlist, src.isFavourite
def handOverMarks(old, new):
    if old.rating > 0: new.rating = old.rating
    if old.onHitlist: new.onHitlist = True
    if old.isFavourite: new.isFavourite = True
def makeDefault(new):
    g = versions(new)
    for old in g:
        if old is not new and old.isDefaultVersion: handOverMarks(old, new)
    for t in g: t.isDefaultVersion = (t is new)
def add(v, src):
    gid = src.groupID or uuid.uuid4()
    if src.groupID is None: src.groupID, src.isDefaultVersion = gid, True
    v.groupID, v.isDefaultVersion = gid, False
    LIB.append(v)
def saveTransposed(src):
    c = Tune(src.name + " transposed"); carryMarks(marksHolder(src), c); add(c, src); return c
def delete(v):
    g = versions(v); rest = [x for x in g if x is not v]
    LIB.remove(v)
    if not rest: return
    succ = rest[0]
    if v.isDefaultVersion: succ.isDefaultVersion = True; handOverMarks(v, succ)
def group(ts):
    gid = uuid.uuid4()
    for i, t in enumerate(ts): t.groupID, t.isDefaultVersion = gid, i == 0
    h = ts[0]
    h.rating = max(t.rating for t in ts)
    h.onHitlist = any(t.onHitlist for t in ts); h.isFavourite = any(t.isFavourite for t in ts)

fails = 0
def check(label, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + label); fails += (not ok)

# 1. Transposed copy of a NON-default version on screen gets the tune's marks.
LIB.clear()
a = Tune("A", rating=4, hit=True); LIB.append(a)
b = Tune("A in G"); add(b, a)
t = saveTransposed(b)
check("transposed copy of a non-default carries the tune's stars", (t.rating, t.onHitlist) == (4, True))
check("the screen reads the default's marks while viewing a version", marksHolder(t) is a)

# 2. Making another version the default keeps the stars in the list.
LIB.clear()
a = Tune("A", rating=5, fav=True); LIB.append(a)
b = Tune("A setting 2"); add(b, a)
makeDefault(b)
check("makeDefault hands stars and heart over", (b.rating, b.isFavourite, b.isDefaultVersion) == (5, True, True))

# 3. A new default that had its own stars keeps them when the old had none.
LIB.clear()
a = Tune("A"); LIB.append(a)
b = Tune("B", rating=3); add(b, a)
makeDefault(b)
check("an empty old default doesn't wipe the new one's marks", b.rating == 3)

# 4. Deleting the default passes the marks on.
LIB.clear()
a = Tune("A", rating=2, hit=True); LIB.append(a)
b = Tune("B"); add(b, a)
delete(a)
check("deleting the default passes marks to the successor", (b.rating, b.onHitlist, b.isDefaultVersion) == (2, True, True))

# 5. Grouping keeps the best of everyone's marks.
LIB.clear()
x, y, z = Tune("X", rating=1), Tune("Y", rating=4, fav=True), Tune("Z", hit=True)
LIB += [x, y, z]; group([x, y, z])
check("grouping keeps highest rating, any hitlist, any heart", (x.rating, x.onHitlist, x.isFavourite) == (4, True, True))

print("\nall passed" if not fails else f"\n{fails} failed"); raise SystemExit(fails)
