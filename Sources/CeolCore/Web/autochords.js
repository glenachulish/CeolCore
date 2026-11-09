// FONN-AUTOCHORDS-1
// Chords for tunes that have none, worked out from the melody — the way a
// guitarist backing a session does it by ear. Shared by abc.html and set.html,
// so the phone, the iPad and the Mac all hear and see the same chords.
//
// Only for a tune with no chord symbols of its own; a tune with even one keeps
// exactly what was written. The tune itself is never changed unless you choose
// "Keep these chords", which writes them into it (ceolKeepableABC).
//
// How the chords are chosen:
//   1. The candidates are the major and minor chords of the tune's key and mode
//      (D mixolydian: D, Em, G, Am, C …; E dorian: Em, F♯m, G, A, Bm, D).
//   2. Each half-bar (a bar, in a waltz, slide or polka; a third, in a slip
//      jig) gets the chord holding most of its melody, the notes on the beat
//      counting for more than the ones between.
//   3. The home chord is favoured, most of all at the start and end of a part,
//      and a chord is kept rather than changed when the new one is barely
//      better — changing every half-bar sounds fussy, not musical.
//
// Plain, as session backing is: mostly the home chord and its neighbours.

var ceolAutoChordsOn = true;
(function () {
  try {
    var saved = localStorage.getItem("ceol.autoChords");
    if (saved === "off") ceolAutoChordsOn = false;
  } catch (e) {}
})();

function ceolSetAutoChords(on) {
  ceolAutoChordsOn = !!on;
  try { localStorage.setItem("ceol.autoChords", ceolAutoChordsOn ? "on" : "off"); } catch (e) {}
}

var CEOL_MODES = {
  "": [0, 2, 4, 5, 7, 9, 11], "maj": [0, 2, 4, 5, 7, 9, 11], "ion": [0, 2, 4, 5, 7, 9, 11],
  "m": [0, 2, 3, 5, 7, 8, 10], "min": [0, 2, 3, 5, 7, 8, 10], "aeo": [0, 2, 3, 5, 7, 8, 10],
  "dor": [0, 2, 3, 5, 7, 9, 10], "mix": [0, 2, 4, 5, 7, 9, 10],
  "lyd": [0, 2, 4, 6, 7, 9, 11], "phr": [0, 1, 3, 5, 7, 8, 10], "loc": [0, 1, 3, 5, 6, 8, 10]
};
var CEOL_STEP_PC = [0, 2, 4, 5, 7, 9, 11];   // C D E F G A B
var CEOL_SHARP_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
var CEOL_FLAT_NAMES = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"];

/// The abc with chords added, and where they went — or null when the tune has
/// chords already, or no key or metre to work from.
///   { text, inserts: [{ at, len }] }   (`at` is in the original text)
function ceolAutoChords(abc) {
  if (!abc || typeof ABCJS === "undefined") return null;
  var tune;
  try { tune = ABCJS.parseOnly(abc)[0]; } catch (e) { return null; }
  if (!tune || !tune.lines) return null;

  // --- key and mode
  var ks = {};
  try { ks = tune.getKeySignature() || {}; } catch (e) {}
  if (!ks.root || ks.root === "none" || ks.root === "HP" || ks.root === "Hp") {
    if (ks.root === "HP" || ks.root === "Hp") ks = { root: "A", acc: "", mode: "Mix", accidentals: ks.accidentals };
    else return null;
  }
  var tonic = (CEOL_STEP_PC["CDEFGAB".indexOf(ks.root.toUpperCase())] +
               (ks.acc === "#" ? 1 : ks.acc === "b" ? -1 : 0) + 12) % 12;
  var scale = CEOL_MODES[(ks.mode || "").toLowerCase().substring(0, 3)] || CEOL_MODES[""];
  var useFlats = (ks.accidentals || []).some(function (a) { return a.acc === "flat"; }) ||
                 ks.acc === "b";
  var keyAcc = {};
  (ks.accidentals || []).forEach(function (a) {
    keyAcc[(a.note || "").toLowerCase()] = a.acc === "sharp" ? 1 : a.acc === "flat" ? -1 : 0;
  });

  // --- candidate chords: the mode's major and minor triads
  var chords = [];
  for (var d = 0; d < 7; d++) {
    var root = (tonic + scale[d]) % 12;
    var third = (tonic + scale[(d + 2) % 7]) % 12;
    var fifth = (tonic + scale[(d + 4) % 7]) % 12;
    var t = (third - root + 12) % 12, f = (fifth - root + 12) % 12;
    if (f !== 7) continue;                         // no diminished chords
    var prior = d === 0 ? 0.3 : (d === 3 || d === 4 || d === 6) ? 0.1 : (d === 5 || d === 2) ? 0.03 : -0.05;
    var name = (useFlats ? CEOL_FLAT_NAMES : CEOL_SHARP_NAMES)[root] + (t === 3 ? "m" : "");
    chords.push({ degree: d, root: root, tones: [root, third, fifth], name: name, prior: prior });
  }
  if (!chords.length) return null;
  var home = chords.filter(function (c) { return c.degree === 0; })[0] || chords[0];

  // --- metre: how the bar is divided
  var mf = { num: 4, den: 4 };
  try { mf = tune.getMeterFraction() || mf; } catch (e) {}
  var num = +mf.num || 4, den = +mf.den || 4;
  var barLen = num / den;
  var parts;
  if (den === 8 && num === 9) parts = 3;
  else if (den === 8 && (num === 6 || num === 12)) parts = 2;
  else if ((num === 3 && den === 4) || (num === 2 && den === 4) || (num === 3 && den === 8)) parts = 1;
  else if (num === 3 && den === 2) parts = 3;
  else parts = 2;
  var segLen = barLen / parts;
  var beatLen = den === 8 && num % 3 === 0 ? 3 / 8 : 1 / den;

  // --- walk the melody (first voice of the first staff) into segments
  var segments = [], seg = null, pos = 0, barAcc = {}, partStart = true, hasChords = false;
  var barCount = 0, barFirstSeg = 0;
  function newSeg(index) {
    seg = { index: index, notes: [], at: -1, partStart: partStart, partEnd: false };
    partStart = false;
    segments.push(seg);
  }
  tune.lines.forEach(function (line) {
    if (!line.staff || !line.staff[0] || !line.staff[0].voices) return;
    (line.staff[0].voices[0] || []).forEach(function (el) {
      if (el.el_type === "bar") {
        var ty = el.type || "";
        var ends = /repeat|thin_thick|thin_thin|thick_thin|dbl/.test(ty);
        if (ends && seg) seg.partEnd = /right|thin_thick|thin_thin|dbl/.test(ty);
        if (ends) partStart = true;
        // A pickup — the notes before the first full bar — gets no chord: the
        // backing comes in on the downbeat, and the first full bar is the
        // part's start.
        if (barCount === 0 && pos > 1e-6 && pos < barLen - 1e-6) {
          for (var k = barFirstSeg; k < segments.length; k++) segments[k].pickup = true;
          partStart = true;
        }
        if (pos > 1e-6) barCount++;
        pos = 0; barAcc = {}; seg = null; barFirstSeg = segments.length;
        return;
      }
      if (el.el_type !== "note") return;
      if (el.chord) el.chord.forEach(function (c) { if (c.position === "default") hasChords = true; });
      var dur = el.duration || 0;
      var index = Math.min(parts - 1, Math.floor((pos + 1e-6) / segLen));
      if (!seg || seg.index !== index) newSeg(index);
      if (el.pitches && el.pitches.length && !el.rest) {
        var p = el.pitches[0];
        var step = ((p.pitch % 7) + 7) % 7;
        var letter = "cdefgab"[step];
        var acc;
        if (p.accidental) {
          acc = { sharp: 1, flat: -1, natural: 0, dblsharp: 2, dblflat: -2 }[p.accidental] || 0;
          barAcc[letter + p.pitch] = acc;
        } else if (barAcc.hasOwnProperty(letter + p.pitch)) {
          acc = barAcc[letter + p.pitch];
        } else {
          acc = keyAcc[letter] || 0;
        }
        var pc = (CEOL_STEP_PC[step] + acc + 12) % 12;
        var onSeg = Math.abs(pos - index * segLen) < 1e-6;
        var onBeat = Math.abs(pos / beatLen - Math.round(pos / beatLen)) < 1e-6;
        var w = Math.max(dur, 1 / 16) * (onSeg ? 2 : onBeat ? 1.5 : 1);
        seg.notes.push({ pc: pc, w: w, strong: onSeg || onBeat });
        if (seg.at < 0 && typeof el.startChar === "number") seg.at = el.startChar;
      }
      pos += dur;
    });
  });
  if (hasChords || !segments.length) return null;
  if (segments.length) segments[segments.length - 1].partEnd = true;

  // --- choose
  function score(c, s) {
    var total = 0, got = 0;
    s.notes.forEach(function (n) {
      total += n.w;
      var i = c.tones.indexOf(n.pc);
      if (i === 0) got += 1.15 * n.w;
      else if (i > 0) got += (i === 1 ? 1 : 0.9) * n.w;
      else if (n.strong) got -= 0.6 * n.w;
    });
    return got + c.prior * total;
  }
  var inserts = [], prev = null;
  segments.forEach(function (s) {
    if (s.at < 0 || !s.notes.length || s.pickup) return;
    var best = null, bestScore = -1e9;
    chords.forEach(function (c) {
      var sc = score(c, s);
      if (sc > bestScore) { bestScore = sc; best = c; }
    });
    var choice = best;
    if ((s.partStart || s.partEnd) && score(home, s) >= 0.75 * bestScore) choice = home;
    else if (prev && score(prev, s) >= 0.9 * bestScore) choice = prev;
    // A part's first chord is always written, even if it's the same as the
    // last one — a reader starting there needs to know.
    if (choice !== prev || s.partStart) {
      inserts.push({ at: s.at, text: '"' + choice.name + '"' });
      prev = choice;
    }
  });
  if (!inserts.length) return null;

  // --- write them in, from the end so the earlier positions stay true
  var text = abc;
  inserts.sort(function (a, b) { return b.at - a.at; });
  inserts.forEach(function (ins) { text = text.substring(0, ins.at) + ins.text + text.substring(ins.at); });
  return {
    text: text,
    inserts: inserts.map(function (i) { return { at: i.at, len: i.text.length }; }).reverse()
  };
}

/// A position in the text with chords back to the same place in the original.
/// Inside an added chord, it is the note the chord stands on.
function ceolAutoChordsMapBack(inserts, n) {
  var shift = 0;
  for (var i = 0; i < inserts.length; i++) {
    var start = inserts[i].at + shift;      // where it sits in the new text
    if (n < start) break;
    if (n < start + inserts[i].len) return inserts[i].at;
    shift += inserts[i].len;
  }
  return n - shift;
}
