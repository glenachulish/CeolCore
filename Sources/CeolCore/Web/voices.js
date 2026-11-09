// Melody instruments, and where their samples come from.
//
// Shared by abc.html (one tune) and set.html (a set), which have to agree:
// change the instrument on a tune and it should still be the instrument when
// you open a set.
//
// abcjs asks for samples at <base><name>-mp3/<note>.mp3, where <name> comes
// from the MIDI program number. Left alone it asks a CDN, so no signal means
// no sound. The Swift side answers the "ceolsf" scheme from the app bundle
// first, then a cache of anything played before, and only then the CDN — so
// the common instruments work in a hall with no reception.
//
// The voice id is abcjs's own name for the program, with one exception:
// Concert Flute and Irish Flute are both program 73, so "mflute" carries the
// distinction through the URL for the handler to pick up.

var CEOL_VOICES = [
  { id: "flute",                 label: "Irish Flute",   program: 73,  offline: true },
  { id: "mflute",                label: "Concert Flute", program: 73,  offline: true },
  { id: "whistle",               label: "Tin Whistle",   program: 78,  offline: true },
  { id: "violin",                label: "Fiddle",        program: 40,  offline: true },
  { id: "accordion",             label: "Accordion",     program: 21 },
  { id: "banjo",                 label: "Banjo",         program: 105 },
  { id: "acoustic_guitar_nylon", label: "Guitar",        program: 24,  offline: true },
  { id: "orchestral_harp",       label: "Harp",          program: 46 },
  { id: "acoustic_grand_piano",  label: "Piano",         program: 0 },
];

var CEOL_CDN_FONT = "https://paulrosen.github.io/midi-js-soundfonts/FluidR3_GM/";

// These samples sit around −22 dBFS, the level abcjs assumes when it applies
// its ×3 multiplier to the fonts it ships with. Passing 3 explicitly keeps the
// volume where it has always been; without it a custom font URL silently drops
// to ×1 and everything plays a third as loud.
var CEOL_FONT_GAIN = 3;

var melodyVoice = "flute";
var melodyProgram = 73;
var chordsOn = true;

// -- The accompaniment ---------------------------------- CEOL_ACCOMP_MARKER_18AUG2026 --
//
// abcjs plays the chord symbols written in the ABC. Left alone it plays them on
// its own default instrument, which is why every tune in this app has been
// backed by the same guitar since the day chords started sounding: nobody had
// ever said otherwise.
//
// These two say otherwise. They are synth options, not notation: abcjs takes
// chordprog / bassprog / chordvol / bassvol in the object handed to setTune and
// uses them as the defaults for any tune that does not carry its own MIDI
// directive. That order matters -- a tune whose ABC specifies its own
// accompaniment keeps it, and this is only the answer for the ones that do not.
//
// Nothing here is written into the ABC, so nothing here travels into an export.
// Which instrument backs you while you practise is a listening choice, not a
// fact about the tune.
var accompVoice = "";     // "" = the default backing: a nylon-string guitar
var accompVol = 85;       // MIDI velocity, 0-127

// -- How the accompaniment is played ------------------------- FONN-ACCOMP-2 --
//
// Left to itself abcjs backs every chord with "boom-chick": a bass note, then
// the whole chord struck at once, on every beat, as loud as the bass, and on a
// piano unless told otherwise. That is what made the backing sound intrusive.
// A guitarist backing a tune doesn't do that, so there are three styles:
//
//   picked   (the default) — fingerstyle: the bass on the main beats and the
//            chord's notes one at a time between, softer than the bass.
//   strummed — a light strum on the off-beats, the bass on the downbeats.
//   classic  — abcjs's own boom-chick, as it always was.
//
// The patterns are abcjs's %%MIDI gchord language, one letter per quaver: f the
// bass, c the whole chord, z a rest, G/H/I the chord's root, third and fifth.
// They depend on the metre, so they're worked out per tune (ceolGchordFor).
var accompStyle = "picked";
var CEOL_DEFAULT_BACKING = "acoustic_guitar_nylon";

(function restore() {
  try {
    // The app is the authority now — it pushes the chosen instrument in via
    // ceolApplySound as soon as the page is up. This still reads the stored
    // value so the page renders sensibly in the instant before that arrives,
    // and because both sides default to the flute they never disagree.
    var saved = localStorage.getItem("ceol.voice");
    if (!saved) {
      // Before instruments had ids they were stored as bare program numbers.
      var p = parseInt(localStorage.getItem("ceol.program"), 10);
      // 74 was a stand-in for the tin whistle: GM 78 is a person whistling,
      // which never sounded like an instrument. Now that real whistle samples
      // are bundled, 78 means the whistle again and 74 should follow it back.
      if (p === 74 || p === 78) saved = "whistle";
      else if (p >= 0) {
        for (var i = 0; i < CEOL_VOICES.length; i++) {
          if (CEOL_VOICES[i].program === p) { saved = CEOL_VOICES[i].id; break; }
        }
      }
    }
    if (saved && ceolVoice(saved)) melodyVoice = saved;
    chordsOn = localStorage.getItem("ceol.chords") !== "off";
    var acc = localStorage.getItem("ceol.accomp");
    if (acc && ceolVoice(acc)) accompVoice = acc;
    var style = localStorage.getItem("ceol.accompStyle");
    if (style === "picked" || style === "strummed" || style === "classic") accompStyle = style;
    var vol = parseInt(localStorage.getItem("ceol.accompVol"), 10);
    if (vol >= 0 && vol <= 127) accompVol = vol;
  } catch (e) {}
  melodyProgram = ceolVoice(melodyVoice).program;
})();

function ceolVoice(id) {
  for (var i = 0; i < CEOL_VOICES.length; i++) {
    if (CEOL_VOICES[i].id === id) return CEOL_VOICES[i];
  }
  return null;
}

function ceolSetAccomp(id) {
  accompVoice = (id && ceolVoice(id)) ? id : "";
  try { localStorage.setItem("ceol.accomp", accompVoice); } catch (e) {}
}

function ceolSetAccompVol(v) {
  v = parseInt(v, 10);
  if (isNaN(v)) return;
  accompVol = Math.max(0, Math.min(127, v));
  try { localStorage.setItem("ceol.accompVol", String(accompVol)); } catch (e) {}
}

function ceolSetAccompStyle(style) {
  if (style !== "picked" && style !== "strummed" && style !== "classic") return;
  accompStyle = style;
  try { localStorage.setItem("ceol.accompStyle", accompStyle); } catch (e) {}
}

/// The gchord pattern for a metre and style, or null for abcjs's own.
/// One letter per quaver of the bar (abcjs counts 8 × num / den of them), and
/// abcjs sounds each letter for exactly one quaver — so a rest really is
/// silence. The first strummed patterns had rests between the strums and
/// came out as a short chord on beats two and four with nothing round it
/// (FONN-ACCOMP-3); a strum fills the bar, the way a guitarist's hand keeps
/// moving whether or not it touches the strings.
function ceolGchordFor(num, den, style) {
  if (style === "classic" || !num || !den) return null;
  var slots = Math.round(8 * num / den);
  if (slots < 2) return null;
  var picked = style === "picked";
  // Waltzes and mazurkas: the bass, then the chord on two and three.
  if (num === 3 && den === 4) return picked ? "fIHIHI" : "fccccc";
  var unit;
  if (den === 8 && num % 3 === 0) {
    unit = picked ? "fIH" : "fcc";             // jigs, slip jigs, slides: in threes
  } else if (slots % 4 === 0) {
    unit = picked ? "fIHI" : "fccc";           // reels, hornpipes, polkas: in twos
  } else if (slots % 3 === 0) {
    unit = picked ? "fIH" : "fcc";
  } else if (slots % 2 === 0) {
    unit = picked ? "fI" : "fc";
  } else {
    return null;
  }
  var out = "";
  while (out.length < slots) out += unit;
  return out.substring(0, slots);
}

function ceolSetVoice(id) {
  if (!ceolVoice(id)) return;
  melodyVoice = id;
  melodyProgram = ceolVoice(id).program;
  try {
    localStorage.setItem("ceol.voice", id);
    localStorage.setItem("ceol.program", String(melodyProgram));
  } catch (e) {}
}

// Fill the dropdown from the list above, so both pages offer the same choices.
function ceolFillVoiceSelect(select) {
  if (!select || select.dataset.filled) return;
  select.dataset.filled = "1";
  select.innerHTML = "";
  for (var i = 0; i < CEOL_VOICES.length; i++) {
    var opt = document.createElement("option");
    opt.value = CEOL_VOICES[i].id;
    opt.textContent = CEOL_VOICES[i].label;
    select.appendChild(opt);
  }
}

// Which base URL to hand abcjs. Normally the offline scheme; the CDN only if
// the scheme turns out not to answer, so a page that somehow can't reach the
// handler still makes a noise rather than failing silently.
var _ceolFontOK = true;
function ceolFontBase() {
  return _ceolFontOK ? ("ceolsf://ceol/" + melodyVoice + "/") : CEOL_CDN_FONT;
}

// Ask for a note we know is bundled. If the request can't even be made, the
// scheme isn't reaching Swift and the CDN is the better bet.
//
// Nothing may be primed until this has answered. The synth loads its samples
// once, when the tune is handed to it — so if the check is still in flight at
// that moment, the tune gets primed against a URL we haven't established works
// and plays in silence, while the next tune opened gets it right. That is
// exactly the "no sound on the first set, fine on the next one" that turned up
// in use. So: ask first, prime second.
var _ceolFontChecked = false;
var _ceolFontWaiting = [];

function ceolWhenFontReady(fn) {
  if (_ceolFontChecked) { fn(); return; }
  _ceolFontWaiting.push(fn);
}

function _ceolFontSettled(ok) {
  if (_ceolFontChecked) return;
  _ceolFontOK = ok;
  _ceolFontChecked = true;
  var waiting = _ceolFontWaiting;
  _ceolFontWaiting = [];
  waiting.forEach(function (fn) { try { fn(); } catch (e) {} });
}

(function probe() {
  try {
    var xhr = new XMLHttpRequest();
    xhr.open("GET", "ceolsf://ceol/flute/flute-mp3/D5.mp3", true);
    xhr.responseType = "arraybuffer";
    xhr.onload = function () {
      _ceolFontSettled(xhr.status === 200 && xhr.response && xhr.response.byteLength > 0);
    };
    xhr.onerror = function () { _ceolFontSettled(false); };
    xhr.send();
    // Never leave the music waiting on a check that has stalled.
    setTimeout(function () { _ceolFontSettled(false); }, 2000);
  } catch (e) { _ceolFontSettled(false); }
})();

/// `visual` is the tune about to be played, for its metre (FONN-ACCOMP-2).
function audioParams(visual) {
  var params = {
    program: melodyProgram,
    chordsOff: !chordsOn,
    soundFontUrl: ceolFontBase(),
    soundFontVolumeMultiplier: CEOL_FONT_GAIN,
    chordvol: accompVol,
    bassvol: accompVol,
  };
  // Always a real instrument now: nothing chosen means a nylon-string guitar,
  // which is what the app's menu has always said it was (abcjs's own default
  // is a piano). A tune whose ABC names its own accompaniment still keeps it.
  var backing = ceolVoice(accompVoice) || ceolVoice(CEOL_DEFAULT_BACKING);
  if (backing) {
    params.chordprog = backing.program;
    params.bassprog = backing.program;
  }
  if (accompStyle !== "classic") {
    var m = null;
    try { if (visual && visual.getMeterFraction) m = visual.getMeterFraction(); } catch (e) {}
    var pattern = m ? ceolGchordFor(+m.num, +m.den, accompStyle) : null;
    if (pattern) params.gchord = pattern;
    // Under the tune, not beside it: the plucked notes a little softer than
    // the bass, and both below the level chosen for the old boom-chick.
    params.bassvol = Math.round(accompVol * 0.8);
    // A strum is every chord note on every quaver, so it sits lower still.
    params.chordvol = Math.round(accompVol * (accompStyle === "picked" ? 0.65 : 0.55));
  }
  // FONN-STRUM-1: abcjs strikes a chord's notes all at once, so "strummed"
  // came out as a soft three-note pluck and sounded like the picking. The
  // shaping happens on the note list abcjs builds, before it fetches samples,
  // so any string added here gets its sample loaded like the rest.
  params.ceolStrum = accompStyle === "strummed";
  params.ceolStrumPattern = strumPattern;
  ceolHookStrum(visual);
  return params;
}

// -- Strumming -------------------------------------------- FONN-STRUM-2 --
//
// abcjs strikes a chord's notes all at once, softly, with the bass alone on
// the beat -- a pluck, not a strum. So in strummed style the chord track is
// rebuilt the way a guitarist would play it:
//
//   * real open-chord shapes worked out on the six strings (E A D G B E),
//     frets 0-4, from the lowest string that has the root -- D is the
//     familiar xx0232, G 320003, Em 022000;
//   * a strumming pattern, not a stroke on every quaver. The hand keeps
//     moving down-up but misses some strokes, which is where the swing of a
//     strum comes from (reels "D . d u . u d u", jigs "D . u D . u");
//   * down-strokes run low to high across every string, a little over a
//     hundredth of a second apart; up-strokes catch the top three, high to
//     low; the beat is the strongest, the up-strokes lightest;
//   * strings ring on until the hand comes back to them, rather than being
//     cut off after a quaver -- the ring is most of what makes it a guitar;
//   * a steel-string guitar rather than the nylon one when the backing is
//     the plain guitar: brighter, and what you hear strumming in a session.
//
// abcjs's own bass notes are dropped: the lowest string of the shape is the
// bass, as it is on a guitar.

var CEOL_STRUM_STRINGS = [40, 45, 50, 55, 59, 64];   // E2 A2 D3 G3 B3 E4
// One letter per quaver from the start of the bar:
//   D  a full down-stroke        d  a lighter down-stroke (top five strings)
//   u  an up-stroke (top three)  .  the hand moves but misses the strings
//   B  the bass string alone     A  the alternate bass (the next string up)
//   c  a chuck: a short, damped down-stroke on the top four strings
var CEOL_STRUM_PATTERNS = {
  folk: {
    "4/4": "D.du.udu", "2/2": "D.du.udu", "4/8": "D.du", "2/4": "D.du",
    "6/8": "D.uD.u", "9/8": "D.uD.uD.u", "12/8": "D.uD.uD.uD.u",
    "3/4": "D.dudu", "3/8": "D.u", "6/4": "D.duduD.dudu"
  },
  steady: {
    "4/4": "DuduDudu", "2/2": "DuduDudu", "4/8": "Dudu", "2/4": "Dudu",
    "6/8": "DudDud", "9/8": "DudDudDud", "12/8": "DudDudDudDud",
    "3/4": "Dududu", "3/8": "Dud", "6/4": "DududuDududu"
  },
  light: {
    "4/4": "D.d.D.d.", "2/2": "D.d.D.d.", "4/8": "D.d.", "2/4": "D.d.",
    "6/8": "D..D..", "9/8": "D..D..D..", "12/8": "D..D..D..D..",
    "3/4": "D.d.d.", "3/8": "D..", "6/4": "D.d.d.D.d.d."
  },
  boomchuck: {
    "4/4": "B.c.A.c.", "2/2": "B.c.A.c.", "4/8": "B.c.", "2/4": "B.c.",
    "6/8": "B..c..", "9/8": "B..c..A..", "12/8": "B..c..A..c..",
    "3/4": "B.c.c.", "3/8": "B..", "6/4": "B.c.c.A.c.c."
  }
};
var strumPattern = "folk";
try {
  var _sp = localStorage.getItem("ceol.strumPattern");
  if (_sp && CEOL_STRUM_PATTERNS[_sp]) strumPattern = _sp;
} catch (e) {}

function ceolSetStrumPattern(name) {
  if (!CEOL_STRUM_PATTERNS[name]) return;
  strumPattern = name;
  try { localStorage.setItem("ceol.strumPattern", name); } catch (e) {}
}
var CEOL_NYLON = 24, CEOL_STEEL = 25;

/// The chord's notes on a guitar in first position: one pitch per string
/// from the lowest string that can sound the root, or null if it can't.
function ceolGuitarShape(pitches) {
  if (!pitches || pitches.length < 2) return null;
  var sorted = pitches.slice().sort(function (a, b) { return a - b; });
  var root = ((sorted[0] % 12) + 12) % 12;
  var tones = {};
  sorted.forEach(function (p) { tones[((p % 12) + 12) % 12] = true; });
  var shape = [], started = false;
  for (var s = 0; s < CEOL_STRUM_STRINGS.length; s++) {
    var open = CEOL_STRUM_STRINGS[s], fret;
    if (!started) {
      for (fret = 0; fret <= 4; fret++) {
        if ((open + fret) % 12 === root) break;
      }
      if (fret > 4) continue;              // this string is left unplayed
      started = true;
      shape.push(open + fret);
      continue;
    }
    // The lowest chord note on this string -- unless it only repeats the
    // string below, as an open B under Bm would; then the next one up.
    var pick = -1;
    for (fret = 0; fret <= 4; fret++) {
      if (!tones[(open + fret) % 12]) continue;
      if (pick < 0) pick = open + fret;
      if (open + fret !== shape[shape.length - 1]) { pick = open + fret; break; }
    }
    if (pick >= 0) shape.push(pick);
  }
  return shape.length >= 3 ? shape : null;
}

/// Fallback for anything the shapes can't place: the chord's notes and their
/// octaves, the five nearest the middle of the guitar.
function ceolStrumVoicing(pitches) {
  var shape = ceolGuitarShape(pitches);
  if (shape) return shape;
  var pool = {};
  pitches.forEach(function (p) {
    [-12, 0, 12].forEach(function (o) {
      var q = p + o;
      if (q >= 45 && q <= 71) pool[q] = true;
    });
  });
  var notes = Object.keys(pool).map(Number);
  notes.sort(function (a, b) { return Math.abs(a - 57) - Math.abs(b - 57) || a - b; });
  notes = notes.slice(0, 5).sort(function (a, b) { return a - b; });
  return notes.length ? notes : pitches.slice().sort(function (a, b) { return a - b; });
}

function ceolShapeStrum(flat, msPerWhole, meter, patternName) {
  if (!flat || !flat.tracks || !(msPerWhole > 0)) return;
  var QUAVER = 0.125;
  var key = meter ? meter.num + "/" + meter.den : "";
  var table = CEOL_STRUM_PATTERNS[patternName] || CEOL_STRUM_PATTERNS.folk;
  var pattern = table[key] || null;
  var slots = meter ? Math.round(8 * meter.num / meter.den) : 8;
  if (!pattern || pattern.length !== slots) pattern = null;
  var gapMs = { D: 13, d: 10, u: 8, B: 0, A: 0, c: 7 };
  var level = { D: 1.15, d: 0.9, u: 0.66, B: 1.2, A: 1.1, c: 0.95 };

  for (var t = 1; t < flat.tracks.length; t++) {
    var track = flat.tracks[t];
    var notes = [], others = [];
    track.forEach(function (e) {
      (e.cmd === "note" && typeof e.pitch === "number" ? notes : others).push(e);
    });
    if (!notes.length) continue;
    var groups = [], byStart = {};
    notes.forEach(function (n) {
      var k = Math.round(n.start * 10000);
      if (!byStart[k]) { byStart[k] = { start: n.start, notes: [] }; groups.push(byStart[k]); }
      byStart[k].notes.push(n);
    });
    groups.sort(function (a, b) { return a.start - b.start; });
    var chordGroups = groups.filter(function (g) { return g.notes.length >= 2; });
    if (chordGroups.length < 2) continue;      // not a chord track

    // Where each bar begins: abcjs's bass falls on the first quaver of it.
    var anchor = null;
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].notes.length === 1) { anchor = groups[i].start; break; }
    }
    if (anchor === null) anchor = groups[0].start;

    // The harmony at each quaver, from whatever abcjs sounded there.
    var slotChord = [];                      // [{start, pitches, template, base}]
    groups.forEach(function (g) {
      var idx = Math.round((g.start - anchor) / QUAVER);
      var pitches = g.notes.length >= 2 ? g.notes.map(function (n) { return n.pitch; }) : null;
      var base = 0;
      g.notes.forEach(function (n) { base = Math.max(base, n.volume || 0); });
      var prev = slotChord[idx];
      slotChord[idx] = {
        start: anchor + idx * QUAVER, pitches: pitches || (prev && prev.pitches) || null,
        template: g.notes[0], base: g.notes.length >= 2 ? base : (prev ? prev.base : 0)
      };
    });
    // A bass slot takes the chord that follows it.
    var lastIdx = slotChord.length - 1;
    for (var j = lastIdx; j >= 0; j--) {
      var sc = slotChord[j];
      if (!sc) continue;
      if (!sc.pitches || !sc.base) {
        var nx = slotChord[j + 1];
        if (nx && nx.pitches) {
          if (!sc.pitches) sc.pitches = nx.pitches;
          if (!sc.base) sc.base = nx.base;
        }
      }
    }

    // The strokes.
    var strokes = [];
    for (var q = 0; q <= lastIdx; q++) {
      var c = slotChord[q];
      if (!c || !c.pitches) continue;
      var pos = ((q % slots) + slots) % slots;
      var kind = pattern ? pattern.charAt(pos) : (pos === 0 ? "D" : (pos % 2 ? "u" : "d"));
      if (kind === ".") continue;
      var shape = ceolStrumVoicing(c.pitches);
      var strings;
      if (kind === "u") strings = shape.slice(-3).reverse();
      else if (kind === "d") strings = shape.length > 4 ? shape.slice(1) : shape;
      else if (kind === "B" || kind === "A") {
        // The bass: the lowest root on the guitar for B, the lowest fifth for
        // A -- D's boom is the open D string, its alternate the open A below.
        var rootPc = ((shape[0] % 12) + 12) % 12;
        var want = kind === "B" ? rootPc : (rootPc + 7) % 12;
        var low = 40;
        while (((low % 12) + 12) % 12 !== want) low++;
        strings = [low];
      }
      else if (kind === "c") strings = shape.slice(-4);
      else strings = shape;
      strokes.push({ start: c.start, kind: kind, strings: strings,
                     chordKey: shape.join(","), template: c.template,
                     base: c.base || 40 });
    }

    var out = [];
    var endOfMusic = slotChord[lastIdx] ? slotChord[lastIdx].start + QUAVER : 0;
    strokes.forEach(function (st, si) {
      var gap = gapMs[st.kind] / msPerWhole;
      st.strings.forEach(function (pitch, k) {
        // Ring until the hand next comes back to this string, or the chord
        // changes (the fingers move), or a beat and a half has gone by.
        var until = endOfMusic + QUAVER;
        for (var n = si + 1; n < strokes.length; n++) {
          var later = strokes[n];
          if (later.chordKey !== st.chordKey || later.strings.indexOf(pitch) >= 0) {
            until = later.start; break;
          }
        }
        // A chuck is damped straight away; everything else rings.
        until = Math.min(until, st.start + QUAVER * (st.kind === "c" ? 0.9 : 3));
        var start = st.start + k * gap;
        if (until - start < QUAVER * 0.3) until = start + QUAVER * 0.3;
        var shade = 1 - 0.04 * k;
        var e = {};
        for (var f in st.template) e[f] = st.template[f];
        e.pitch = pitch;
        e.start = start;
        e.duration = until - start;
        e.volume = Math.max(1, Math.min(127, Math.round(st.base * level[st.kind] * shade)));
        if (e.instrument === CEOL_NYLON) e.instrument = CEOL_STEEL;
        out.push(e);
      });
    });
    others.forEach(function (e) {
      if (e.cmd === "program" && e.instrument === CEOL_NYLON) e.instrument = CEOL_STEEL;
    });
    out.sort(function (x, y) { return x.start - y.start; });
    flat.tracks[t] = others.concat(out);
  }
}

/// Let the strum reshape what abcjs is about to play. Wrapped once per tune;
/// the wrapper only acts when the options ask for it.
function ceolHookStrum(visual) {
  if (!visual || typeof visual.setUpAudio !== "function" || visual._ceolStrumHooked) return;
  visual._ceolStrumHooked = true;
  var original = visual.setUpAudio;
  visual.setUpAudio = function (options) {
    var flat = original.apply(this, arguments);
    if (options && options.ceolStrum) {
      try {
        var m = this.getMeterFraction ? this.getMeterFraction() : null;
        var perBar = this.millisecondsPerMeasure ? this.millisecondsPerMeasure(flat && flat.tempo) : 0;
        var barFraction = m && m.num && m.den ? m.num / m.den : 1;
        ceolShapeStrum(flat, perBar / barFraction, m, options.ceolStrumPattern);
      } catch (e) {}
    }
    return flat;
  };
}
