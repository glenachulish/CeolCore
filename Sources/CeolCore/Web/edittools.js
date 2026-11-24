// FONN-COMPOSE-1, FONN-STYLE-1, FONN-CHORDEDIT-1
// What the Compose, Swing & Ornaments and Chords pages share: reading a tune
// into notes that know their bar, beat and length, and writing changes back
// into the ABC text at the exact characters abcjs says each note came from.
//
// abcjs does the reading (ABCJS.parseOnly), so durations already account for
// broken rhythm (A>B), triplets and the L: line. Nothing here re-parses ABC
// with a home-made grammar except the few characters of a single note.
//
// Pure functions only: no DOM. Checked under node with tools/verify_edittools.js.

var CEOL_LETTERS = "CDEFGAB";

// ── Reading ─────────────────────────────────────────────────────────────────

/// The unit note length from the L: line, as a fraction of a whole note.
function ceolUnitLength(abc, meter) {
  var m = /(^|\n)L:\s*(\d+)\s*\/\s*(\d+)/.exec(abc || "");
  if (m) return (+m[2]) / (+m[3]);
  // ABC's own default: 1/16 for metres under 3/4, otherwise 1/8.
  if (meter && meter.num / meter.den < 0.75) return 1 / 16;
  return 1 / 8;
}

/// Where the body starts: the character after the K: line.
function ceolBodyStart(abc) {
  var m = /(^|\n)K:[^\n]*\n?/.exec(abc || "");
  return m ? m.index + m[0].length : 0;
}

/// The R: line, lower-cased ("reel", "jig", "strathspey" …), or "".
function ceolTuneType(abc) {
  var m = /(^|\n)R:\s*([^\n]*)/.exec(abc || "");
  return m ? m[2].trim().toLowerCase() : "";
}

/// The pieces of one note's text: everything before the pitch (chords,
/// decorations, grace notes), the accidental, letter, octave marks, the
/// length, and whatever follows (a tie). Null for anything else — chords in
/// brackets, rests written oddly.
function ceolSplitNote(text) {
  var m = /^((?:"[^"]*"|![^!]*!|\+[^+]*\+|[.~HLMOPSTuv]|\{[^}]*\}|\s)*)([_^=]{0,2})([A-Ga-g])([,']*)(\d*(?:\/+\d*)?)([\s\S]*)$/.exec(text);
  if (!m) return null;
  return { prefix: m[1], acc: m[2], letter: m[3], marks: m[4], len: m[5], rest: m[6] };
}

/// A note's height as a number of scale steps: C = 0, c = 7, c' = 14, C, = -7.
function ceolStepIndex(letter, marks) {
  var commas = (marks.match(/,/g) || []).length;
  var apos = (marks.match(/'/g) || []).length;
  var upper = letter === letter.toUpperCase();
  var octave = (upper ? 0 : 1) - commas + apos;
  return octave * 7 + CEOL_LETTERS.indexOf(letter.toUpperCase());
}

/// The letter for a step index, back the other way.
function ceolStepLetter(index) {
  var octave = Math.floor(index / 7);
  var letter = CEOL_LETTERS[((index % 7) + 7) % 7];
  if (octave >= 1) return letter.toLowerCase() + Array(octave).join("'");
  return letter + Array(-octave + 1).join(",");
}

/// A length, as a fraction of a whole note, written in units of L.
function ceolLengthText(whole, unit) {
  var units = whole / unit;
  if (Math.abs(units - 1) < 1e-9) return "";
  if (Math.abs(units - Math.round(units)) < 1e-9) return String(Math.round(units));
  // Halves and quarters of a unit: /, /4 …
  for (var d = 2; d <= 16; d *= 2) {
    var n = units * d;
    if (Math.abs(n - Math.round(n)) < 1e-9) {
      n = Math.round(n);
      return (n === 1 ? "" : String(n)) + (d === 2 ? "/" : "/" + d);
    }
  }
  return String(units);
}

/// The tune read into bars of notes.
///
///   { meter: {num, den}, barLen, beatLen, unit, type, bodyStart,
///     notes: [{ s, e, text, dur, pos, beat, bar, rest, invisible,
///               triplet, chordRanges: [[s, e, name]] , el }],
///     bars: [{ index, notes: [indexes], len, pickup }] }
///
/// `pos` is from the start of the bar, as a fraction of a whole note, and for
/// a pickup bar it is measured back from the bar line it leads into, so the
/// last note of a pickup sits on the last beat where it is heard.
function ceolReadTune(abc) {
  if (!abc || typeof ABCJS === "undefined") return null;
  var tune;
  try { tune = ABCJS.parseOnly(abc)[0]; } catch (e) { return null; }
  if (!tune || !tune.lines) return null;
  var meter = { num: 4, den: 4 };
  try { meter = tune.getMeterFraction() || meter; } catch (e) {}
  meter = { num: +meter.num || 4, den: +meter.den || 4 };
  var barLen = meter.num / meter.den;
  var beatLen = (meter.den === 8 && meter.num % 3 === 0) ? 3 / 8 : 1 / meter.den;
  var unit = ceolUnitLength(abc, meter);
  var out = { tune: tune, meter: meter, barLen: barLen, beatLen: beatLen, unit: unit,
              type: ceolTuneType(abc), bodyStart: ceolBodyStart(abc), notes: [], bars: [] };

  var bar = { index: 0, notes: [], len: 0, pickup: false, start: -1, end: -1 };
  var pos = 0, tripletLeft = 0, tripletMult = 1;
  function closeBar(barEl) {
    bar.len = pos;
    if (barEl) bar.end = barEl.startChar;
    if (bar.notes.length) {
      // A short first bar is a pickup: its notes lead into the bar line.
      if (out.bars.length === 0 && pos < barLen - 1e-6) {
        bar.pickup = true;
        var shift = barLen - pos;
        bar.notes.forEach(function (i) {
          out.notes[i].pos += shift;
          out.notes[i].beat = Math.floor((out.notes[i].pos + 1e-9) / beatLen);
        });
      }
      out.bars.push(bar);
    }
    bar = { index: out.bars.length, notes: [], len: 0, pickup: false,
            start: barEl ? barEl.endChar : -1, end: -1 };
    pos = 0;
  }
  tune.lines.forEach(function (line) {
    if (!line.staff || !line.staff[0] || !line.staff[0].voices) return;
    (line.staff[0].voices[0] || []).forEach(function (el) {
      if (el.el_type === "bar") { closeBar(el); return; }
      if (el.el_type !== "note") return;
      if (typeof el.startChar !== "number") return;
      if (el.startTriplet) {
        tripletLeft = el.startTriplet;
        tripletMult = el.tripletMultiplier || (2 / 3);
      }
      var inTriplet = tripletLeft > 0;
      var dur = (el.duration || 0) * (inTriplet ? tripletMult : 1);
      // abcjs's range runs on over the spaces after a note and a broken
      // rhythm mark (A> B). Those belong between notes, not to one of them.
      var text = abc.slice(el.startChar, el.endChar).replace(/[\s<>]+$/, "");
      var end = el.startChar + text.length;
      var chordRanges = [];
      var re = /"([^"]*)"/g, m;
      while ((m = re.exec(text))) {
        var name = m[1];
        if (/^[\^_<>@]/.test(name)) continue;     // annotations, not chords
        chordRanges.push([el.startChar + m.index, el.startChar + m.index + m[0].length, name]);
      }
      if (bar.start < 0) bar.start = el.startChar;
      var note = {
        s: el.startChar, e: end, text: text, dur: dur, pos: pos,
        beat: Math.floor((pos + 1e-9) / beatLen), bar: out.bars.length,
        rest: !!el.rest, invisible: !!(el.rest && el.rest.type === "invisible"),
        triplet: inTriplet, graces: !!el.gracenotes,
        decorated: !!(el.decoration && el.decoration.length),
        chordRanges: chordRanges,
        pitch: (el.pitches && el.pitches[0]) ? el.pitches[0].pitch : null,
        multi: !!(el.pitches && el.pitches.length > 1)
      };
      bar.notes.push(out.notes.length);
      out.notes.push(note);
      pos += dur;
      if (inTriplet) { tripletLeft--; if (tripletLeft <= 0) tripletMult = 1; }
    });
  });
  closeBar(null);
  return out;
}

/// Edits [{s, e, text}] applied from the end, so earlier positions stay true.
/// Overlapping edits are dropped (the later-starting one wins the overlap).
function ceolApplyEdits(abc, edits) {
  edits = edits.slice().sort(function (a, b) { return b.s - a.s || b.e - a.e; });
  var out = abc, floor = Infinity;
  edits.forEach(function (ed) {
    if (ed.e > floor) return;
    out = out.slice(0, ed.s) + ed.text + out.slice(ed.e);
    floor = ed.s;
  });
  return out;
}

function ceolNear(a, b) { return Math.abs(a - b) < 1e-6; }

// ── Swing and snaps ─────────────────────────────────────────────────────────

/// Pairs of equal notes filling one beat, starting on it, in simple time:
/// the places a hornpipe lilt (A>B) or a Scotch snap (A<B) can go.
function ceolBeatPairs(t) {
  var pairs = [];
  if (!t || ceolNear(t.beatLen, 3 / 8)) return pairs;
  var half = t.beatLen / 2;
  for (var i = 0; i + 1 < t.notes.length; i++) {
    var a = t.notes[i], b = t.notes[i + 1];
    if (a.bar !== b.bar || a.rest || b.rest || a.triplet || b.triplet || a.multi || b.multi) continue;
    if (!ceolNear(a.pos % t.beatLen, 0) && !ceolNear(a.pos % t.beatLen, t.beatLen)) continue;
    var even = ceolNear(a.dur, half) && ceolNear(b.dur, half);
    var dotted = ceolNear(a.dur + b.dur, t.beatLen) && (ceolNear(a.dur, half * 1.5) || ceolNear(a.dur, half * 0.5));
    if (!even && !dotted) continue;
    pairs.push({ a: a, b: b, even: even, beat: Math.round(a.pos / t.beatLen) });
  }
  return pairs;
}

/// The characters between two notes of a pair, if they are only a broken
/// rhythm mark and spaces. Null if anything else (a tie, a bar) is there.
function ceolBetween(abc, a, b) {
  var gap = abc.slice(a.e, b.s);
  if (/^\s*[<>]*\s*$/.test(gap) && !/-\s*$/.test(a.text)) return gap;
  return null;
}

/// style: "lilt" (A>B on every beat), "snap" (A<B on the beats given by
/// `snapBeats`, A>B on the rest — a strathspey), "straight" (both plain).
function ceolSwing(abc, style, snapBeats) {
  var t = ceolReadTune(abc);
  if (!t) return { abc: abc, changed: 0, note: "This tune couldn't be read." };
  if (ceolNear(t.beatLen, 3 / 8)) {
    return { abc: abc, changed: 0,
             note: "This tune is in " + t.meter.num + "/" + t.meter.den + ": its beats are already in threes, so there are no pairs to swing." };
  }
  snapBeats = snapBeats || [1, 3];
  var edits = [];
  ceolBeatPairs(t).forEach(function (p) {
    var gap = ceolBetween(abc, p.a, p.b);
    if (gap === null) return;
    // Write each note's written length as a plain unit pair; the mark does
    // the rest. A dotted pair written out as A3B (L:1/16) becomes A>B too.
    var sa = ceolSplitNote(p.a.text), sb = ceolSplitNote(p.b.text);
    if (!sa || !sb) return;
    // A rhythm mark tucked inside a slur's end — (G>)A — is left alone.
    if (/[<>]/.test(sa.rest) || /[<>]/.test(sb.rest)) return;
    var plain = ceolLengthText(t.beatLen / 2, t.unit);
    var mark = style === "straight" ? "" :
      (style === "snap" && snapBeats.indexOf(p.beat) >= 0) ? "<" : ">";
    var newA = sa.prefix + sa.acc + sa.letter + sa.marks + plain + sa.rest;
    var newB = sb.prefix + sb.acc + sb.letter + sb.marks + plain + sb.rest;
    var before = p.a.text + gap + p.b.text;
    var after = newA + mark + newB;
    if (before !== after) edits.push({ s: p.a.s, e: p.b.e, text: after });
  });
  return { abc: ceolApplyEdits(abc, edits), changed: edits.length, note: "" };
}

// ── Ornaments ───────────────────────────────────────────────────────────────

/// The regional styles. Each is a recipe of the same building blocks, so a
/// region is one entry here, not new code. They are rules of thumb drawn from
/// how each tradition is usually described and taught — a starting point to
/// play with and edit, not a transcription of any particular player.
///
///   rolls:   "long" (dotted crotchets in jigs, slides, slip jigs),
///            "both" (and crotchets in reels and hornpipes), or none
///   crans:   a cran instead of a roll on low D and E (flute and pipes)
///   trebles: on crotchets — "repeat" (3AAA, or "turn" (3ABA
///   above / below: a single grace note on long beat notes, from above, or
///            sliding up from below
///   cuts:    "repeat" (between repeated notes), "beat" (and on beat quavers)
///   pipeG:   pipe-style G grace notes (high g, or a on g) instead of cuts
///   doublings: Highland pipe doublings on beat notes
///   snaps:   Scotch snaps in strathspeys and highlands
///   …From:   the lowest "How much" level (1–3) at which that one appears
var CEOL_ORNAMENT_STYLES = [
  { id: "sligo", region: "Ireland", name: "Sligo and Roscommon",
    about: "The flowing flute style: rolls on long notes and crotchets, crans on low D and E, cuts between repeated notes.",
    rules: { rolls: "both", crans: true, cuts: "repeat" } },
  { id: "leitrim", region: "Ireland", name: "Leitrim",
    about: "Driving flute playing: strong cuts on the beat as well as between repeated notes, long rolls and crans.",
    rules: { rolls: "long", crans: true, cuts: "beat" } },
  { id: "clare", region: "Ireland", name: "Clare",
    about: "Spare and rhythmic: a few rolls on the long notes of the strong beats and little else.",
    rules: { rolls: "long", rollFrom: 2, cuts: "repeat", cutFrom: 3 } },
  { id: "kerry", region: "Ireland", name: "Kerry (Sliabh Luachra)",
    about: "Polkas and slides played for the dance: notes slid into from below, cuts between repeated notes, rolls only at the most.",
    rules: { below: true, cuts: "repeat", rolls: "long", rollFrom: 3 } },
  { id: "donegal", region: "Ireland", name: "Donegal",
    about: "The driving fiddle style: trebles on crotchets, cuts, few rolls, and Scotch snaps in highlands and strathspeys.",
    rules: { trebles: "repeat", cuts: "repeat", rolls: "long", rollFrom: 3, snaps: true } },
  { id: "speyside", region: "Scotland", name: "Speyside and the North-East",
    about: "The strathspey country: sharp Scotch snaps and dotted rhythms, grace notes on long notes, birls (fast triplets) at the most.",
    rules: { snaps: true, above: true, trebles: "repeat", trebleFrom: 3, cuts: "repeat", cutFrom: 3 } },
  { id: "westcoast", region: "Scotland", name: "West Highland",
    about: "Pipe-influenced fiddle and box playing: high G grace notes on the long beat notes (every beat note, and doublings, at the most), between repeated notes, and snaps in strathspeys.",
    rules: { pipeG: true, doublings: true, doublingFrom: 3, snaps: true } },
  { id: "shetland", region: "Scotland", name: "Shetland",
    about: "Lively fiddle playing: triplet turns on crotchets, notes slid into from below, cuts between repeated notes.",
    rules: { trebles: "turn", below: true, belowFrom: 2, cuts: "repeat" } },
  { id: "pipes", region: "Scotland", name: "Highland pipes",
    about: "Doublings on the beat notes and G grace notes between repeated notes, as a piper plays them. Only notes on the pipe scale (low G to high A) are gracenoted.",
    rules: { doublings: true, pipeG: true, pipeRepeatsOnly: true } }
];

/// Names from the first version of this page, to today's.
var CEOL_STYLE_ALIASES = { "irish-flowing": "sligo", "irish-sparse": "clare", "scottish": "speyside" };

function ceolStyleRules(id) {
  id = CEOL_STYLE_ALIASES[id] || id;
  for (var i = 0; i < CEOL_ORNAMENT_STYLES.length; i++) {
    if (CEOL_ORNAMENT_STYLES[i].id === id) return CEOL_ORNAMENT_STYLES[i].rules;
  }
  return null;
}

/// Is this note one a style may touch at all?
function ceolPlain(n) {
  return !n.rest && !n.triplet && !n.graces && !n.decorated && !n.multi && n.pitch !== null &&
         !/-\s*$/.test(n.text);
}

/// Does `density` allow ornamenting this beat of the bar? 1: the first beat
/// only; 2: the strong beats (first and middle); 3: every beat.
function ceolDensityAllows(t, n, density) {
  if (density >= 3) return true;
  var beats = Math.round(t.barLen / t.beatLen);
  if (density === 1) return n.beat === 0;
  return n.beat === 0 || (beats >= 4 && n.beat === beats / 2) ||
         (beats === 2 && n.beat === 1 && ceolNear(t.beatLen, 3 / 8));
}

function ceolOnBeat(t, n) {
  var r = n.pos / t.beatLen;
  return Math.abs(r - Math.round(r)) < 1e-6;
}

/// Piping doublings, by the note's step index (G = 4 … a = 12).
var CEOL_PIPE_DOUBLINGS = {
  4: "{gGd}", 5: "{gAd}", 6: "{gBd}", 7: "{gcd}", 8: "{gde}",
  9: "{gef}", 10: "{gfg}", 11: "{gf}", 12: "{ag}"
};

/// The pipe-style single grace note: high g, or a on g itself; nothing on
/// high a or off the pipe scale.
function ceolPipeG(idx) {
  if (!CEOL_PIPE_DOUBLINGS[idx] || idx === 12) return null;
  return idx === 11 ? "{a}" : "{g}";
}

/// One note rewritten with an ornament, or null to leave it.
function ceolOrnamentNote(t, n, rules, density) {
  var sp = ceolSplitNote(n.text);
  if (!sp || sp.rest.replace(/\s/g, "") !== "") return null;
  if (!ceolOnBeat(t, n) || !ceolDensityAllows(t, n, density)) return null;
  var at = function (from) { return density >= (from || 1); };
  var idx = ceolStepIndex(sp.letter, sp.marks);
  var bare = sp.letter + sp.marks;                 // the pitch, no accidental
  var first = sp.prefix + sp.acc + bare;           // keeps chords, accidental
  var compound = ceolNear(t.beatLen, 3 / 8);
  var q = ceolLengthText(compound ? 1 / 8 : t.beatLen / 2, t.unit);
  var up = "{" + ceolStepLetter(idx + 1) + "}";
  var down = "{" + ceolStepLetter(idx - 1) + "}";
  var dotted = compound && ceolNear(n.dur, 3 / 8);
  var crotchet = !compound && ceolNear(t.beatLen, 1 / 4) && ceolNear(n.dur, 1 / 4);
  var longish = dotted || crotchet || n.dur >= t.beatLen * 0.75 - 1e-9;
  var lowDE = idx === 1 || idx === 2;

  if (rules.doublings && CEOL_PIPE_DOUBLINGS[idx] && at(rules.doublingFrom) &&
      n.dur >= t.beatLen / 2 - 1e-9) {
    return CEOL_PIPE_DOUBLINGS[idx] + first + sp.len;
  }
  if (dotted && rules.rolls && at(rules.rollFrom)) {
    if (rules.crans && lowDE) {
      return "{" + ceolStepLetter(idx + 4) + "}" + first + q +
             "{" + ceolStepLetter(idx + 3) + "}" + bare + q +
             "{" + ceolStepLetter(idx + 2) + "}" + bare + q;
    }
    return first + q + up + bare + q + down + bare + q;        // long roll
  }
  if (crotchet && rules.trebles && at(rules.trebleFrom)) {
    if (rules.trebles === "turn") return "(3" + first + q + ceolStepLetter(idx + 1) + q + bare + q;
    return "(3" + first + q + bare + q + bare + q;              // a treble
  }
  if (crotchet && rules.rolls === "both" && at(rules.rollFrom)) {
    if (rules.crans && lowDE) return "{" + ceolStepLetter(idx + 4) + "}" + first + q + "{" + ceolStepLetter(idx + 2) + "}" + bare + q;
    return up + first + q + down + bare + q;                    // short roll
  }
  if ((longish || density >= 3) && rules.pipeG && !rules.pipeRepeatsOnly) {
    var g = ceolPipeG(idx);
    if (g) return g + first + sp.len;
  }
  if (longish && rules.above && at(rules.aboveFrom)) return up + first + sp.len;
  if (longish && rules.below && at(rules.belowFrom)) return down + first + sp.len;
  return null;
}

/// A cut (a grace note from above) on the second of two repeated notes, or,
/// with cuts: "beat", on a plain quaver on the beat.
function ceolCutNote(t, prev, n, rules, density) {
  if (!ceolPlain(n)) return null;
  var repeat = !!prev && ceolPlain(prev) && prev.pitch === n.pitch && prev.bar === n.bar;
  var quaver = ceolNear(n.dur, ceolNear(t.beatLen, 3 / 8) ? 1 / 8 : t.beatLen / 2);
  var beatCut = rules.cuts === "beat" && quaver && ceolOnBeat(t, n) && ceolDensityAllows(t, n, density);
  if (!repeat && !beatCut) return null;
  // At "some", repeated-note cuts only where the second note is on a beat.
  if (density < 3 && !beatCut && !ceolOnBeat(t, n)) return null;
  var sp = ceolSplitNote(n.text);
  if (!sp) return null;
  var idx = ceolStepIndex(sp.letter, sp.marks);
  var grace = rules.pipeG ? ceolPipeG(idx) : "{" + ceolStepLetter(idx + 1) + "}";
  if (!grace) return null;
  return sp.prefix + grace + sp.acc + sp.letter + sp.marks + sp.len + sp.rest;
}

/// Ornament a tune in a style. Returns { abc, changed, note }.
function ceolOrnament(abc, style, density) {
  var rules = ceolStyleRules(style);
  if (!rules) return { abc: abc, changed: 0, note: "No such style." };
  density = density || 2;
  // Strathspeys and highlands are snapped first, so the short note of each
  // snap isn't then given a grace note meant for a long one.
  var snaps = 0;
  if (rules.snaps && /strathspey|highland/.test(ceolTuneType(abc))) {
    var snapped = ceolSwing(abc, "snap", [1, 3]);
    abc = snapped.abc;
    snaps = snapped.changed;
  }
  var t = ceolReadTune(abc);
  if (!t) return { abc: abc, changed: 0, note: "This tune couldn't be read." };
  var edits = [], touched = {};
  t.notes.forEach(function (n, i) {
    if (!ceolPlain(n)) return;
    var text = ceolOrnamentNote(t, n, rules, density);
    if (text !== null && text !== n.text) {
      edits.push({ s: n.s, e: n.e, text: text });
      touched[i] = true;
    }
  });
  if ((rules.cuts || rules.pipeG) && density >= (rules.cutFrom || 2)) {
    for (var i = 0; i < t.notes.length; i++) {
      if (touched[i] || (i > 0 && touched[i - 1])) continue;
      var text = ceolCutNote(t, t.notes[i - 1], t.notes[i], rules, density);
      if (text !== null) { edits.push({ s: t.notes[i].s, e: t.notes[i].e, text: text }); touched[i] = true; }
    }
  }
  var note = "";
  if (!edits.length && !snaps) note = "Nothing in this tune fits that style's ornaments at this level. Try more ornaments, or another style.";
  return { abc: ceolApplyEdits(abc, edits), changed: edits.length + snaps, note: note };
}

var CEOL_ORNAMENT_DECORATIONS = /^!(trill|roll|turn|turnx|invertedturn|invertedturnx|mordent|lowermordent|uppermordent|pralltriller|slide|arpeggio|trill\(|trill\))!$/;

/// Take ornaments out: grace notes, ~ rolls and !decorations! in the body.
/// Trebles written as (3AAA are kept: they are notes, not ornaments.
function ceolStripOrnaments(abc) {
  var start = ceolBodyStart(abc);
  var head = abc.slice(0, start), body = abc.slice(start);
  var count = 0;
  body = body.split(/("[^"]*"|%[^\n]*)/).map(function (part, i) {
    if (i % 2 === 1) return part;              // chord symbols and comments stay
    // Decorations are read in pairs of ! from the left, so !2!A!4! is two
    // fingerings and a note; only the ornament ones go.
    return part.replace(/\{[^}]*\}|![^!\n]*!|~/g, function (m) {
      if (m[0] === "!" && !CEOL_ORNAMENT_DECORATIONS.test(m)) return m;
      count++;
      return "";
    });
  }).join("");
  return { abc: head + body, changed: count };
}

// ── Chords ──────────────────────────────────────────────────────────────────

var CEOL_EDIT_MODES = {
  "": [0, 2, 4, 5, 7, 9, 11], "maj": [0, 2, 4, 5, 7, 9, 11], "ion": [0, 2, 4, 5, 7, 9, 11],
  "m": [0, 2, 3, 5, 7, 8, 10], "min": [0, 2, 3, 5, 7, 8, 10], "aeo": [0, 2, 3, 5, 7, 8, 10],
  "dor": [0, 2, 3, 5, 7, 9, 10], "mix": [0, 2, 4, 5, 7, 9, 10],
  "lyd": [0, 2, 4, 6, 7, 9, 11], "phr": [0, 1, 3, 5, 7, 8, 10], "loc": [0, 1, 3, 5, 6, 8, 10]
};
var CEOL_EDIT_PC = [0, 2, 4, 5, 7, 9, 11];
var CEOL_EDIT_SHARPS = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
var CEOL_EDIT_FLATS = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"];
var CEOL_ROMAN = ["I", "II", "III", "IV", "V", "VI", "VII"];

/// The chords that belong to the tune's key: the mode's major and minor
/// triads, home chord first, then the dominant seventh where the mode has
/// one. [{ name, roman }]
function ceolKeyChords(t) {
  var ks = {};
  try { ks = t.tune.getKeySignature() || {}; } catch (e) {}
  if (!ks.root || ks.root === "none") return [];
  if (ks.root === "HP" || ks.root === "Hp") ks = { root: "A", acc: "", mode: "Mix", accidentals: [] };
  var tonic = (CEOL_EDIT_PC["CDEFGAB".indexOf(ks.root.toUpperCase())] +
               (ks.acc === "#" ? 1 : ks.acc === "b" ? -1 : 0) + 12) % 12;
  var scale = CEOL_EDIT_MODES[(ks.mode || "").toLowerCase().substring(0, 3)] || CEOL_EDIT_MODES[""];
  var flats = (ks.accidentals || []).some(function (a) { return a.acc === "flat"; }) || ks.acc === "b";
  var names = flats ? CEOL_EDIT_FLATS : CEOL_EDIT_SHARPS;
  var out = [];
  for (var d = 0; d < 7; d++) {
    var root = (tonic + scale[d]) % 12;
    var third = ((tonic + scale[(d + 2) % 7]) - root + 24) % 12;
    var fifth = ((tonic + scale[(d + 4) % 7]) - root + 24) % 12;
    if (fifth !== 7) continue;
    var minor = third === 3;
    out.push({ name: names[root] + (minor ? "m" : ""),
               roman: minor ? CEOL_ROMAN[d].toLowerCase() : CEOL_ROMAN[d], degree: d });
    if (d === 4 && !minor) out.push({ name: names[root] + "7", roman: "V7", degree: 4.5 });
  }
  return out;
}

/// How many chord places a bar has by default: a bar in 3/4, 2/4 and 12/8,
/// thirds in 9/8, halves otherwise — the same division the made-up chords use.
function ceolDefaultSlots(t) {
  var n = t.meter.num, d = t.meter.den;
  if (d === 8 && n === 9) return 3;
  if ((n === 3 && d === 4) || (n === 2 && d === 4) || (n === 3 && d === 8) || (d === 8 && n === 12)) return 1;
  if (n === 3 && d === 2) return 3;
  return 2;
}

/// Every bar's chord places: [{ bar, slot, from, to, first (note index or -1),
/// notes: [indexes], chords: [names written there] }].
function ceolChordSlots(t, perBar) {
  var slots = [];
  perBar = perBar || ceolDefaultSlots(t);
  t.bars.forEach(function (bar, b) {
    var len = t.barLen / perBar;
    for (var k = 0; k < perBar; k++) {
      var from = k * len, to = (k + 1) * len;
      var slot = { bar: b, slot: k, from: from, to: to, first: -1, notes: [], chords: [] };
      bar.notes.forEach(function (i) {
        var n = t.notes[i];
        if (n.pos >= from - 1e-6 && n.pos < to - 1e-6) {
          slot.notes.push(i);
          if (slot.first < 0 && !n.invisible) slot.first = i;
          n.chordRanges.forEach(function (c) { slot.chords.push(c[2]); });
        }
      });
      if (slot.notes.length) slots.push(slot);
    }
  });
  return slots;
}

/// Set (or with name "" clear) the chord for one slot: every chord written in
/// the slot goes, and the new one stands on its first note.
function ceolSetSlotChord(abc, t, slot, name) {
  var edits = [];
  slot.notes.forEach(function (i) {
    t.notes[i].chordRanges.forEach(function (c) { edits.push({ s: c[0], e: c[1], text: "" }); });
  });
  if (name && slot.first >= 0) {
    var at = t.notes[slot.first].s;
    var clean = String(name).replace(/"/g, "").trim();
    if (clean) edits.push({ s: at, e: at, text: '"' + clean + '"' });
  }
  // Removal and insertion at the same place must both happen; give the
  // insertion a zero-width slot just before any removal there.
  // Applied from the end; at one place the removal goes first, then the
  // insertion, so the new chord isn't removed with the old one.
  edits.sort(function (a, b) { return b.s - a.s || (b.e - b.s) - (a.e - a.s); });
  var out = abc;
  edits.forEach(function (ed) { out = out.slice(0, ed.s) + ed.text + out.slice(ed.e); });
  return out;
}

/// Every chord symbol out of the body.
function ceolClearChords(abc) {
  var start = ceolBodyStart(abc);
  var body = abc.slice(start).replace(/"([^"]*)"/g, function (m, name) {
    return /^[\^_<>@]/.test(name) ? m : "";
  });
  return abc.slice(0, start) + body;
}

/// Move every chord by a number of semitones (Òrain's "tap a chord and the
/// others follow"): names only, the notes are left alone.
function ceolShiftChords(abc, semis, flats) {
  var start = ceolBodyStart(abc);
  var names = flats ? CEOL_EDIT_FLATS : CEOL_EDIT_SHARPS;
  function shiftRoot(r) {
    var pc = CEOL_EDIT_PC["CDEFGAB".indexOf(r[0].toUpperCase())];
    if (r[1] === "#") pc++; else if (r[1] === "b") pc--;
    return names[((pc + semis) % 12 + 24) % 12];
  }
  var body = abc.slice(start).replace(/"([A-G][#b]?)([^"\/]*)(?:\/([A-G][#b]?))?"/g, function (m, root, rest, bass) {
    return '"' + shiftRoot(root) + rest + (bass ? "/" + shiftRoot(bass) : "") + '"';
  });
  return abc.slice(0, start) + body;
}

// ── Composing ───────────────────────────────────────────────────────────────

/// Metre, bars per part, tempo and filler for each tune type.
var CEOL_COMPOSE_TYPES = {
  "reel":       { m: "4/4", q: "1/4=100", bar: 8 },
  "jig":        { m: "6/8", q: "3/8=110", bar: 6 },
  "slip jig":   { m: "9/8", q: "3/8=110", bar: 9 },
  "hornpipe":   { m: "4/4", q: "1/4=80",  bar: 8 },
  "polka":      { m: "2/4", q: "1/4=130", bar: 4 },
  "slide":      { m: "12/8", q: "3/8=130", bar: 12 },
  "strathspey": { m: "4/4", q: "1/4=70",  bar: 8 },
  "march":      { m: "2/4", q: "1/4=90",  bar: 4 },
  "waltz":      { m: "3/4", q: "1/4=120", bar: 6 },
  "mazurka":    { m: "3/4", q: "1/4=120", bar: 6 },
  "barndance":  { m: "4/4", q: "1/4=90",  bar: 8 },
  "air":        { m: "3/4", q: "1/4=60",  bar: 6 }
};

/// A new tune with its sections in place: header lines, and two parts of
/// eight empty bars each, repeated. The empty bars are invisible rests
/// (x8 in a reel), which abcjs draws as empty bars to be filled.
function ceolComposeTemplate(o) {
  o = o || {};
  var type = (o.type || "reel").toLowerCase();
  var spec = CEOL_COMPOSE_TYPES[type] || CEOL_COMPOSE_TYPES["reel"];
  var meter = o.meter || spec.m;
  var filler = "x" + (o.meter ? ceolFillerUnits(meter) : spec.bar);
  var empty = function () {
    var four = [filler, filler, filler, filler].join(" | ");
    return "|: " + four + " |\n" + four + " :|";
  };
  var lines = ["X:1", "T:" + (o.title || "New tune")];
  if (o.composer) lines.push("C:" + o.composer);
  lines.push("R:" + type, "M:" + meter, "L:1/8", "Q:" + spec.q);
  lines.push("% Each x" + filler.slice(1) + " below is an empty bar waiting for notes.");
  lines.push("K:" + (o.key || "D"));
  lines.push("P:A", empty(), "P:B", empty());
  return lines.join("\n") + "\n";
}

/// How many quavers fill a bar of a metre ("6/8" → 6, "4/4" → 8).
function ceolFillerUnits(meter) {
  var m = /^(\d+)\/(\d+)$/.exec(String(meter).trim());
  if (!m) return 8;
  return Math.max(1, Math.round((+m[1]) / (+m[2]) * 8));
}

/// The tune ready to keep: empty bars gone, half-filled bars topped up with
/// real rests, empty parts and the template's comment removed. Returns "" if
/// there are no notes at all.
function ceolComposeFinal(abc) {
  var start = ceolBodyStart(abc);
  var head = abc.slice(0, start).replace(/^% Each x\d+ below is an empty bar waiting for notes\.\n/m, "");
  var body = abc.slice(start);
  // Split on bar lines, keeping them.
  // Endings (|1, :|2, [2) are bar lines too, or an empty second-time bar
  // would read as notes.
  var parts = body.split(/(:\|[12]|:\|:|::|:\|\]?|\|\]|\|\||\|:|\[\||\|\[?[12]?|\[[12])/);
  var kept = [];
  for (var i = 0; i < parts.length; i += 2) {
    var seg = parts[i], delim = parts[i + 1] || "";
    var hasNotes = /[A-Ga-gzZ]/.test(seg.replace(/"[^"]*"|![^!]*!|%[^\n]*|^[A-Za-z]:[^\n]*$/gm, "").replace(/x\d*/g, ""));
    var onlyFiller = /^\s*(x\d*(\/+\d*)?\s*)+$/.test(seg);
    if (onlyFiller) {
      // Drop an empty bar with the plain bar line after it; keep repeat
      // and ending marks, which belong to the structure.
      kept.push({ seg: seg.replace(/x\d*(\/+\d*)?/g, "").replace(/[ \t]+/g, " "), delim: delim, empty: true });
    } else {
      kept.push({ seg: hasNotes ? seg.split(/("[^"]*")/).map(function (p, j) {
        return j % 2 ? p : p.replace(/x(\d*(?:\/+\d*)?)/g, "z$1");
      }).join("") : seg, delim: delim, empty: false });
    }
  }
  var out = kept.map(function (k) {
    if (k.empty && (k.delim === "|" || k.delim === "")) return k.seg.replace(/[^\n]/g, "");
    return k.seg + k.delim;
  }).join("");
  // Tidy what dropping bars leaves: "|  :|" → ":|", "|: |" → "|:", "| |" → "|".
  for (var pass = 0; pass < 4; pass++) {
    out = out.replace(/\|\s*:\|/g, " :|")
             .replace(/\|:\s*\|(?![:\]])/g, "|:")
             .replace(/\|[ \t]*\|(?![:\]])/g, "|")
             .replace(/\|\n\|(?![:\]])/g, "|\n")
             .replace(/\|:\s*:\|/g, "")
             .replace(/[ \t]{2,}/g, " ")
             .replace(/[ \t]+\n/g, "\n")
             .replace(/\n[ \t]+/g, "\n");
  }
  // Endings with nothing written in the second-time bar: back to a plain repeat.
  out = out.replace(/\|1([^|\n]*):\|2\s*\|\]?/g, "|$1:|");
  // A part with no notes left: its P: line and its bar lines go.
  out = out.replace(/P:[^\n]*\n((?:[\s|:\]\[12]*\n?)*)(?=P:|$)/g, function (m, rest) {
    return /[A-Ga-gzZ]/.test(rest) ? m : "";
  });
  out = out.replace(/\n{2,}/g, "\n").replace(/^\n+/, "");
  if (!/[A-Ga-g]/.test(out.replace(/P:[^\n]*|"[^"]*"/g, ""))) return "";
  return head + out.replace(/\s*$/, "\n");
}

/// A written length after a letter ("3", "/", "3/2", "") in units of L.
function ceolParseUnits(digits, slash) {
  var n = digits === "" || digits === undefined ? 1 : +digits;
  if (!slash) return n;
  var d = slash.replace(/\//g, "") === "" ? Math.pow(2, slash.length) : +slash.replace(/\//g, "");
  return n / d;
}

/// The filler (invisible rest) in the bar from `at` onwards: { s, e, units }
/// of the first one before the next bar line, or null.
function ceolFillerAfter(abc, at) {
  var re = /x(\d*)(\/+\d*)?|\||\n/g, m;
  re.lastIndex = at;
  while ((m = re.exec(abc))) {
    if (m[0] === "|") return null;
    if (m[0] === "\n") continue;
    // Inside a chord name or annotation ("Cmaj7x") it is text, not a rest;
    // on a comment or header line (% …, P:A) it is not music at all.
    var before = abc.slice(abc.lastIndexOf("\n", m.index - 1) + 1, m.index);
    if (((before.match(/"/g) || []).length % 2) === 1) continue;
    if (/^\s*(%|[A-Za-z]:)/.test(before)) continue;
    return { s: m.index, e: m.index + m[0].length, units: ceolParseUnits(m[1], m[2]) };
  }
  return null;
}

function ceolFillerText(units) {
  if (units <= 1e-9) return "";
  return "x" + ceolLengthText(units / 8, 1 / 8);
}

/// Put a note at `at`, taking its length out of the bar's filler. Returns
/// { abc, cursor } with the cursor after the note — moved past the bar line
/// when the bar is full, so the next note goes into the next bar.
function ceolComposeInsert(abc, at, noteText, units) {
  var filler = ceolFillerAfter(abc, at);
  var out = abc, cursor = at;
  if (filler && filler.s >= at) {
    var fillText = ceolFillerText(Math.max(0, filler.units - units));
    out = out.slice(0, filler.s) + fillText + out.slice(filler.e);
    out = out.slice(0, at) + noteText + out.slice(at);
    cursor = at + noteText.length;
    if (!fillText) {
      var rest = out.slice(cursor);
      var jump = /^[ \t]*(?::\|:|::|:\||\|:|\|\]|\|\||\|)?[ \t]*(?:\n(?:P:[^\n]*\n)?)?(?:\|:[ \t]*)?/.exec(rest);
      if (jump) cursor += jump[0].length;
    }
  } else {
    out = abc.slice(0, at) + noteText + abc.slice(at);
    cursor = at + noteText.length;
  }
  return { abc: out, cursor: cursor };
}

/// Take a note out, giving its length back to its bar as filler, so the
/// bar's shape stays and the space can be filled again. Neighbouring fillers
/// in the bar join up (x2x3 → x5).
function ceolComposeDelete(abc, s, e, units) {
  var out = abc.slice(0, s) + ceolFillerText(units) + abc.slice(e);
  // Join fillers next to each other on this bar.
  var lineStart = out.lastIndexOf("\n", s) + 1;
  var lineEnd = out.indexOf("\n", s); if (lineEnd < 0) lineEnd = out.length;
  var line = out.slice(lineStart, lineEnd);
  var joined = line, guard = 0;
  var re = /x(\d*)(\/+\d*)?\s*x(\d*)(\/+\d*)?/;
  while (re.test(joined) && guard++ < 20) {
    joined = joined.replace(re, function (m, a, sa, b, sb) {
      return ceolFillerText(ceolParseUnits(a, sa) + ceolParseUnits(b, sb));
    });
  }
  return { abc: out.slice(0, lineStart) + joined + out.slice(lineEnd), cursor: s };
}

// ── Layout ──────────────────────────────────────────────────────────────────
// FONN-LAYOUT-1. Why a tune comes out strangely on the stave, and the tidy-up.
// Measured in abcjs with Fonn's own wrap settings: its wrapping splits a long
// line but never joins short ones, so every line break in the ABC starts a new
// stave — a tune pasted one bar to a line is drawn one bar to a stave. A blank
// line ends the tune there; an old-style "!" line break swallows notes;
// non-breaking and zero-width spaces from web pages are ignored with warnings.
// Windows line endings, %%staffwidth and the like make no difference.
// The same checks are in Swift (ABCLayout.swift) for the Edit ABC screens.

var CEOL_HIDDEN = /[\u00A0\u200B\u200C\u200D\u2060\uFEFF\u2028\u2029]/;

function ceolIsFieldLine(line) { return /^\s*([A-Za-z]:|%)/.test(line); }

/// A "!" that isn't a decoration like !trill! — old ABC's line break.
var CEOL_BANG = /!(?![^!\s|]{1,24}!)/g;
function ceolStrayBangs(line) {
  // Decorations come in pairs; walk them so !trill!A! leaves the last one.
  var out = [], i = 0, m, re = /![^!\s|]{1,24}!|!/g;
  while ((m = re.exec(line))) { if (m[0] === "!") out.push(m.index); }
  return out;
}

function ceolBarCount(line) {
  return (line.replace(/"[^"]*"/g, "").match(/\|/g) || []).length;
}

/// Problems, most serious first: [{ id, title, detail, fixable }].
function ceolLayoutProblems(abc) {
  var out = [];
  if (!abc) return out;
  var text = abc.replace(/\r\n?/g, "\n");
  var start = ceolBodyStart(text);
  if (!start) return out;
  var lines = text.slice(start).split("\n");
  // FONN-HEADBLANK-1: a blank line between the first header line and K:.
  var headLines = text.slice(0, start).replace(/\n$/, "").split("\n"), seen = false, headBlank = false;
  headLines.forEach(function (l) { if (l.trim()) seen = true; else if (seen) headBlank = true; });
  var lastMusic = -1;
  lines.forEach(function (l, i) { if (l.trim() && !ceolIsFieldLine(l)) lastMusic = i; });
  var blank = false, bangs = false, noBars = false, header = false, secondTune = false, short = 0, music = 0;
  lines.forEach(function (l, i) {
    if (/^\s*X:/.test(l)) secondTune = true;
    if (!l.trim()) { if (i < lastMusic && !secondTune) blank = true; return; }
    if (/^\s*T:/.test(l)) header = true;
    if (ceolIsFieldLine(l)) return;
    music++;
    if (ceolStrayBangs(l).length) bangs = true;
    var bars = ceolBarCount(l);
    var notes = (l.replace(/"[^"]*"|![^!]*!|\{[^}]*\}/g, "").match(/[A-Ga-g]/g) || []).length;
    if (bars === 0 && notes > 24) noBars = true;
    if (bars <= 2 && i !== lastMusic && !/\\\s*$/.test(l)) short++;
  });
  if (blank || headBlank) out.push({ id: "blank", fixable: true, title: "A blank line in the tune",
    detail: "A blank line ends a tune in ABC, so everything after it is dropped without a word. Tidy takes blank lines out of the header and the music." });
  if (bangs) out.push({ id: "bang", fixable: true, title: "Old-style ! line breaks",
    detail: "Older ABC (much of thesession.org's early music) used ! to end a line. Each one forces a new stave there, whatever the width of the screen, and one with no space after it can swallow the notes that follow. Tidy takes them out and lets Fonn lay the bars out itself." });
  if (CEOL_HIDDEN.test(text)) out.push({ id: "hidden", fixable: true, title: "Hidden characters",
    detail: "Non-breaking or zero-width spaces, usually copied from a web page. They can't be seen and the music reader skips them with a warning. Tidy turns them into ordinary spaces or takes them out." });
  if (music >= 3 && short >= Math.max(2, Math.ceil(music / 3))) out.push({ id: "short", fixable: true, title: "Short lines",
    detail: "Each line of ABC starts a new stave, and short lines are never joined, so a tune written a bar or two to a line is drawn a bar or two to a stave. Tidy joins each part into one line and lets Fonn lay out the bars to fit the screen." });
  if (noBars) out.push({ id: "nobars", fixable: false, title: "No bar lines",
    detail: "A long run of notes with no | in it is one enormous bar, which can't be laid out across lines. Put a | at the end of each bar." });
  if (header) out.push({ id: "title", fixable: false, title: "A title inside the music",
    detail: "A T: line after the K: line is drawn as a heading partway through the tune. If it names a part, P:A or P:B is the usual way; otherwise delete it." });
  if (secondTune) out.push({ id: "second", fixable: false, title: "Two tunes in one",
    detail: "There is another X: line further down: this ABC holds more than one tune, and only the first is shown. Copy the second into a tune of its own, then delete it here." });
  return out;
}

/// The tidy-up: line endings, hidden characters, blank lines and stray ! out
/// of the music, and each part's lines joined into one. Header lines, P:,
/// inline fields, comments and lyrics keep their own lines.
function ceolTidyLayout(abc) {
  var text = abc.replace(/\r\n?/g, "\n").replace(/[\u2028\u2029]/g, "\n")
                .replace(/\u00A0/g, " ").replace(/[\u200B\u200C\u200D\u2060\uFEFF]/g, "");
  var start = ceolBodyStart(text);
  if (!start) return text;
  // FONN-HEADBLANK-1: blank lines out of the header too (twin of ABCLayout.tidy).
  var head = text.slice(0, start).split("\n").filter(function (l, i, a) {
    return l.trim() || i === a.length - 1;
  }).join("\n"), lines = text.slice(start).split("\n");
  var hasSecond = lines.some(function (l) { return /^\s*X:/.test(l); });
  var out = [], current = "";
  function flush() { if (current.trim()) out.push(current.replace(/\s+$/, "")); current = ""; }
  for (var i = 0; i < lines.length; i++) {
    var l = lines[i];
    if (/^\s*X:/.test(l)) { flush(); out.push.apply(out, lines.slice(i)); current = ""; break; }
    if (!l.trim()) { if (hasSecond) { flush(); out.push(""); } continue; }
    if (ceolIsFieldLine(l)) { flush(); out.push(l.replace(/\s+$/, "")); continue; }
    var bangs = ceolStrayBangs(l);
    for (var b = bangs.length - 1; b >= 0; b--) l = l.slice(0, bangs[b]) + " " + l.slice(bangs[b] + 1);
    l = l.replace(/\\\s*$/, "").trim();
    if (!l) continue;
    if (!current) current = l;
    else if (/\|\s*$/.test(current) && /^\|/.test(l)) current = current.replace(/\|\s*$/, "") + l;
    else current += (/\|\s*$/.test(current) ? "" : " ") + l;
    // A part ends at a closing repeat, a double bar or a final bar.
    if (/(:\||\|\]|\|\||::)\s*$/.test(current)) flush();
  }
  flush();
  return head + ceolCloseLaterEndings(ceolLeadingFieldsAsLines(out)).join("\n").replace(/\n*$/, "\n");
}

/// FONN-LEADFIELD-1 (twin of ABCLayout.leadingFieldsAsLines). abcjs draws a
/// [M:…]/[K:…] that opens a line at the end of the line before; on a line of
/// its own it is drawn where the new line starts.
/// FONN-CLOSEEND-1 (twin of ABCLayout.closeLaterEndings). A second-time bar
/// ending its line with a plain | before the next part's |: gets ||, or abcjs
/// closes it on the next line and draws a stub of bracket there.
function ceolCloseLaterEndings(lines) {
  var out = lines.slice();
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (/^\s*X:/.test(line)) break;
    if (!line.trim() || ceolIsFieldLine(line)) continue;
    var t = line.replace(/[ \t]+$/, "");
    if (!/\|$/.test(t) || /(\|\||:\||\[\|)$/.test(t)) continue;
    var s = -1;
    for (var j = 0; j < t.length - 1; j++) if ((t[j] === "[" || t[j] === "|") && /[2-9]/.test(t[j + 1])) s = j;
    if (s < 0) continue;
    var tail = t.slice(s + 1);
    if ([":|", "||", "|]", "|:", "::"].some(function (x) { return tail.indexOf(x) >= 0; })) continue;
    var opens = false;
    for (var k = i + 1; k < lines.length; k++) {
      var n = lines[k];
      if (!n.trim()) continue;
      if (ceolIsFieldLine(n)) { if (/^\s*P:/.test(n)) opens = true; continue; }
      if (/^[ \t]*(\|:|\[\||::)/.test(n)) opens = true;
      break;
    }
    if (opens) out[i] = t + "|";
  }
  return out;
}

function ceolLeadingFieldsAsLines(lines) {
  var out = [], second = false;
  lines.forEach(function (line) {
    if (/^\s*X:/.test(line)) second = true;
    if (second || !line.trim() || ceolIsFieldLine(line)) { out.push(line); return; }
    var rest = line.replace(/^[ \t]+/, ""), fields = [], m;
    while ((m = /^\[([MK]:[^\]]*)\][ \t]*/.exec(rest))) { fields.push(m[1].trim()); rest = rest.slice(m[0].length); }
    if (!fields.length) { out.push(line); return; }
    out.push.apply(out, fields);
    if (rest) out.push(rest);
  });
  return out;
}

// ── Snippets ────────────────────────────────────────────────────────────────
// FONN-SNIPPETS-1. The first bars of a tune, enough to bring it back to mind
// (EasyABC calls these incipits): a pickup, if there is one, and the first
// `bars` full bars, ending with a final bar line. The header keeps only what
// draws and plays the music — the title and the rest are shown by the list.

/// The tune's Q: line as crotchets a minute (abcjs's qpm), or null:
/// "1/4=100" → 100, "3/8=110" → 165, "120" → 120.
function ceolTempoQpm(abc) {
  var m = /(^|\n)Q:\s*(?:"[^"]*"\s*)?(?:(\d+)\/(\d+)\s*=\s*)?(\d+)/.exec(abc || "");
  if (!m) return null;
  var bpm = +m[4];
  if (!m[2]) return bpm;
  return Math.round(bpm * 4 * (+m[2]) / (+m[3]));
}

function ceolIncipit(abc, bars) {
  bars = bars || 2;
  var t = ceolReadTune(abc);
  if (!t || !t.bars.length) return null;
  var want = bars + (t.bars[0].pickup ? 1 : 0);
  var last = t.bars[Math.min(want, t.bars.length) - 1];
  var start = t.bodyStart;
  var end = last.end > 0 ? last.end : abc.length;
  var head = abc.slice(0, start).split(/\r?\n/).filter(function (l) {
    return /^(X|M|L|K|V):/.test(l) || /^%%/.test(l);
  });
  if (!head.length || !/^X:/.test(head[0])) head.unshift("X:1");
  var body = abc.slice(start, end).split(/\r?\n/).filter(function (l) {
    return l.trim() && !/^\s*(%|[A-Za-z]:)/.test(l);    // no P:, w:, comments
  }).map(function (l) { return l.replace(/\\\s*$/, ""); }).join(" ");
  // A first ending cut off by the end of the snippet would draw its bracket
  // open-ended: take the marker off.
  body = body.replace(/\|\s*\[?1\s*$/, "|").replace(/\s+$/, "");
  return head.join("\n") + "\n" + body + " |]\n";
}

if (typeof module !== "undefined") {
  module.exports = {
    ceolReadTune: ceolReadTune, ceolSwing: ceolSwing, ceolOrnament: ceolOrnament,
    ceolStripOrnaments: ceolStripOrnaments, ceolKeyChords: ceolKeyChords,
    ceolChordSlots: ceolChordSlots, ceolSetSlotChord: ceolSetSlotChord,
    ceolClearChords: ceolClearChords, ceolShiftChords: ceolShiftChords,
    ceolComposeTemplate: ceolComposeTemplate, ceolComposeFinal: ceolComposeFinal,
    ceolComposeInsert: ceolComposeInsert, ceolFillerAfter: ceolFillerAfter, ceolComposeDelete: ceolComposeDelete,
    ceolSplitNote: ceolSplitNote, ceolStepIndex: ceolStepIndex, ceolStepLetter: ceolStepLetter,
    ceolLengthText: ceolLengthText, CEOL_ORNAMENT_STYLES: CEOL_ORNAMENT_STYLES,
    ceolLayoutProblems: ceolLayoutProblems, ceolTidyLayout: ceolTidyLayout,
    ceolIncipit: ceolIncipit, ceolTempoQpm: ceolTempoQpm
  };
}
