// node tools/library_sweep_edittools.js <library.ceol.json>
// Every tune through every transformation: bar lengths must not change, and
// the result must still parse.
const path = require("path");
global.ABCJS = require(path.join(__dirname, "../Sources/CeolCore/Web/abcjs-basic-min.js"));
const T = require(path.join(__dirname, "../Sources/CeolCore/Web/edittools.js"));
const lib = require(path.resolve(process.argv[2]));
const tunes = lib.tunes.filter(t => t.abc && /\nK:/.test(t.abc));
function lens(abc) { const t = T.ceolReadTune(abc); return t ? t.bars.map(b => Math.round(b.len * 960)).join(",") : null; }
const jobs = [["lilt", a => T.ceolSwing(a, "lilt")], ["straight", a => T.ceolSwing(a, "straight")],
  ["strip", a => T.ceolStripOrnaments(a)]];
T.CEOL_ORNAMENT_STYLES.forEach(s => [1, 2, 3].forEach(d => jobs.push([s.id + d, a => T.ceolOrnament(a, s.id, d)])));
let bad = {}, changed = {}, examples = {};
for (const tune of tunes) {
  const before = lens(tune.abc);
  if (!before) continue;
  for (const [name, fn] of jobs) {
    let r; try { r = fn(tune.abc); } catch (e) { bad[name] = (bad[name] || 0) + 1; examples[name] = tune.title + ": " + e.message; continue; }
    if (r.changed) changed[name] = (changed[name] || 0) + 1;
    if (name === "strip" || name === "lilt" || name === "straight") {
      // Swing keeps each beat the same length too, so bars must match.
    }
    const after = lens(r.abc);
    if (after !== before) { bad[name] = (bad[name] || 0) + 1; if (!examples[name]) examples[name] = tune.title; }
  }
}
// Chord round trip: set every slot, then clear, keeps the notes.
let chordBad = 0;
for (const tune of tunes.slice(0, 400)) {
  let abc = T.ceolClearChords(tune.abc), t = T.ceolReadTune(abc);
  if (!t) continue;
  const before = lens(abc);
  const n = T.ceolChordSlots(t).length;
  for (let i = 0; i < n; i++) { t = T.ceolReadTune(abc); abc = T.ceolSetSlotChord(abc, t, T.ceolChordSlots(t)[i], "G"); }
  const slots = T.ceolChordSlots(T.ceolReadTune(abc));
  if (lens(abc) !== before || slots.some(s => s.first >= 0 && s.chords.join() !== "G")) { chordBad++; if (chordBad < 3) console.log("chord problem:", tune.title); }
}
console.log("tunes:", tunes.length);
console.log("changed:", JSON.stringify(changed));
console.log("bar-length changes:", JSON.stringify(bad));
console.log("examples:", JSON.stringify(examples, null, 1));
console.log("chord round-trip problems:", chordBad);
