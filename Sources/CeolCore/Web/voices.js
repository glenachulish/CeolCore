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
  { id: "acoustic_guitar_nylon", label: "Guitar",        program: 24 },
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
    params.chordvol = Math.round(accompVol * (accompStyle === "picked" ? 0.65 : 0.5));
  }
  // FONN-STRUM-1: abcjs strikes a chord's notes all at once, so "strummed"
  // came out as a soft three-note pluck and sounded like the picking. The
  // shaping happens on the note list abcjs builds, before it fetches samples,
  // so any string added here gets its sample loaded like the rest.
  params.ceolStrum = accompStyle === "strummed";
  ceolHookStrum(visual);
  return params;
}

// -- Strumming -------------------------------------------- FONN-STRUM-1 --
//
// What a guitarist's hand does that abcjs doesn't:
//   * every beat begins with a down-stroke, the bass string first -- the
//     gchord pattern can only put the bass there alone;
//   * a down-stroke crosses five strings, low to high, about 11ms apart;
//     an up-stroke catches the top three, high to low, a little quicker;
//   * the down-stroke on the beat is the strongest, the up-strokes lightest.
// The hand keeps moving down-up across the quavers, counted from each bass
// note, so it lines up with the beat whatever the pickup.

var CEOL_STRUM_DOWN_MS = 11;
var CEOL_STRUM_UP_MS = 8;

/// Five guitar strings' worth of the chord: its notes and their octaves,
/// the five nearest the middle of the guitar's range.
function ceolStrumVoicing(pitches) {
  var pool = {};
  pitches.forEach(function (p) {
    [-12, 0, 12].forEach(function (o) {
      var q = p + o;
      if (q >= 45 && q <= 71) pool[q] = true;   // A2 .. B4
    });
  });
  var notes = Object.keys(pool).map(Number);
  notes.sort(function (a, b) { return Math.abs(a - 57) - Math.abs(b - 57) || a - b; });
  notes = notes.slice(0, 5);
  notes.sort(function (a, b) { return a - b; });
  return notes.length ? notes : pitches.slice().sort(function (a, b) { return a - b; });
}

function ceolShapeStrum(flat, msPerWhole) {
  if (!flat || !flat.tracks || !(msPerWhole > 0)) return;
  var QUAVER = 0.125;
  var downGap = CEOL_STRUM_DOWN_MS / msPerWhole;
  var upGap = CEOL_STRUM_UP_MS / msPerWhole;
  for (var t = 1; t < flat.tracks.length; t++) {
    var track = flat.tracks[t];
    var notes = [], others = [];
    track.forEach(function (e) {
      (e.cmd === "note" && typeof e.pitch === "number" ? notes : others).push(e);
    });
    if (!notes.length) continue;
    // Gather the notes struck together.
    var groups = [], byStart = {};
    notes.forEach(function (n) {
      var key = Math.round(n.start * 10000);
      if (!byStart[key]) { byStart[key] = { start: n.start, notes: [] }; groups.push(byStart[key]); }
      byStart[key].notes.push(n);
    });
    groups.sort(function (a, b) { return a.start - b.start; });
    // Only a chord-and-bass track looks like this: some single bass notes
    // and some chords. A second melody voice is left alone.
    var chordCount = groups.filter(function (g) { return g.notes.length >= 2; }).length;
    if (chordCount < 2) continue;

    var out = [];
    var beatAt = null;
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i];
      var template = g.notes[0];
      var bass = null, chord = null;
      if (g.notes.length === 1) {
        // The bass note: the start of a beat. Strum with it, using the next
        // chord's notes if one follows soon enough to be the same harmony.
        bass = g.notes[0];
        beatAt = g.start;
        var next = groups[i + 1];
        if (next && next.notes.length >= 2 && next.start - g.start <= QUAVER * 1.01) {
          chord = next.notes.map(function (n) { return n.pitch; });
        }
      } else {
        chord = g.notes.map(function (n) { return n.pitch; });
      }
      var slot = beatAt === null ? 0 : Math.round((g.start - beatAt) / QUAVER);
      var down = slot % 2 === 0;
      var accent = !!bass;
      var base = 0;
      g.notes.forEach(function (n) { base = Math.max(base, n.volume || 0); });
      if (bass) {
        out.push(bass);
        var nextChord = groups[i + 1];
        if (nextChord && nextChord.notes.length >= 2) {
          base = 0;
          nextChord.notes.forEach(function (n) { base = Math.max(base, n.volume || 0); });
        }
      }
      if (!chord) continue;
      var strings = ceolStrumVoicing(chord);
      if (!down) strings = strings.slice(-3).reverse();
      var gap = down ? downGap : upGap;
      var level = accent ? 1.2 : (down ? 0.95 : 0.65);
      var end = g.start + (template.duration || QUAVER);
      strings.forEach(function (pitch, k) {
        var start = g.start + (bass && down ? (k + 1) : k) * gap;
        if (start >= end) return;
        // In a down-stroke the lower strings sound a touch fuller.
        var shade = down ? (1 - 0.05 * k) : (1 - 0.06 * k);
        var n = {};
        for (var f in template) n[f] = template[f];
        n.pitch = pitch;
        n.start = start;
        n.duration = end - start;
        n.volume = Math.max(1, Math.min(127, Math.round(base * level * shade)));
        out.push(n);
      });
    }
    out.sort(function (a, b) { return a.start - b.start; });
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
        ceolShapeStrum(flat, perBar / barFraction);
      } catch (e) {}
    }
    return flat;
  };
}
