// node tools/library_sweep_layout.js <library.ceol.json> — the layout check
// and tidy-up over a whole library: tidying must not change a single note.
const path = require("path");
global.ABCJS = require(path.join(__dirname, "../Sources/CeolCore/Web/abcjs-basic-min.js"));
const T = require(path.join(__dirname, "../Sources/CeolCore/Web/edittools.js"));
const lib = require(path.resolve(process.argv[2]));
const tunes = lib.tunes.filter(t => t.abc && /\nK:/.test(t.abc));
const counts = {}; let changedMusic = 0, examples = [], tidied = 0;
function sig(abc) {
  const t = T.ceolReadTune(abc);
  return t ? t.notes.map(n => (n.rest ? "z" : n.pitch) + ":" + Math.round(n.dur * 960)).join(" ") + "|" + t.bars.map(b => Math.round(b.len * 960)).join(",") : "";
}
for (const tune of tunes) {
  const probs = T.ceolLayoutProblems(tune.abc);
  probs.forEach(p => counts[p.id] = (counts[p.id] || 0) + 1);
  const tidy = T.ceolTidyLayout(tune.abc);
  if (tidy !== tune.abc.replace(/\r\n?/g, "\n")) tidied++;
  // A blank line or a stray ! hides music, so tidying may bring notes back;
  // otherwise the notes must be exactly the same.
  if (probs.some(p => p.id === "blank" || p.id === "bang")) continue;
  if (sig(tidy) !== sig(tune.abc)) { changedMusic++; if (examples.length < 3) examples.push(tune.title); }
}
console.log("tunes:", tunes.length, " tidy would change:", tidied);
console.log("problems found:", JSON.stringify(counts));
console.log("music changed by tidying:", changedMusic, examples);
