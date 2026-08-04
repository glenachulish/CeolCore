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
  } catch (e) {}
  melodyProgram = ceolVoice(melodyVoice).program;
})();

function ceolVoice(id) {
  for (var i = 0; i < CEOL_VOICES.length; i++) {
    if (CEOL_VOICES[i].id === id) return CEOL_VOICES[i];
  }
  return null;
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

function audioParams() {
  return {
    program: melodyProgram,
    chordsOff: !chordsOn,
    soundFontUrl: ceolFontBase(),
    soundFontVolumeMultiplier: CEOL_FONT_GAIN,
  };
}
