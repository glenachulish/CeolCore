// FONN-LIVESOUND-1 (9 Nov 2026): rendering must not wait for the speaker.
//
// abcjs begins every render with audioContext.resume() and does nothing more
// until that promise settles. In the app the page's own audio sits idle --
// the native player does the sounding -- and WebKit can leave an idle page's
// context suspended or interrupted with resume() pending until the music is
// next touched. The first tune was fine; a change of instrument, backing or
// style made from the Sound panel waited, the page gave up after 8 seconds,
// and the player went on with the recording it already had. Only opening
// another tune (another page) seemed to apply it.
//
// Working out the waveform needs no running context: the samples decode and
// the notes mix into an ordinary buffer either way. So resume() is still
// asked for, but anything waiting on it is let go after a short wait. When
// the page plays through Web Audio itself the resume comes from a tap and
// settles at once, so nothing there changes.
(function ceolPatientResume() {
  function patch(C) {
    if (!C || !C.prototype || C.prototype._ceolPatient) return;
    var original = C.prototype.resume;
    if (typeof original !== "function") return;
    C.prototype._ceolPatient = true;
    C.prototype.resume = function () {
      var asked;
      try { asked = original.apply(this, arguments); } catch (e) { asked = null; }
      var letGo = new Promise(function (done) { setTimeout(done, 300); });
      if (!asked || !asked.then) return letGo;
      return Promise.race([asked.catch(function () {}), letGo]);
    };
  }
  try { patch(window.AudioContext); } catch (e) {}
  try { patch(window.webkitAudioContext); } catch (e) {}
})();

// Playing a passage straight through, ignoring what's written.
//
// When you set a loop from one bar to another, you want to hear those bars,
// once each, round and round. What you got instead was the written repeats:
// looping from the middle of the A part to the middle of the B part played
// the A part's repeat on the way, and looping across two tunes of a set
// played whatever the first tune's :| sent it back to.
//
// The audio is a fixed buffer with the repeats already baked into it, so
// there's no seeking around them. The answer is to play a version of the tune
// with the repeat marks taken out — the same notes on the page, each heard
// once, in written order. Bar three is then bar three, and a loop is exactly
// the music between its ends.
//
// Checked against 500 tunes from the library: 498 keep an identical page of
// notes, 439 play shorter (the repeats gone), none play longer.

/// Take the repeat marks out of a stretch of music. The notes are untouched —
/// only the instructions to go back and play them again.
///
/// The first and second ending brackets are deliberately left alone. Removing
/// them as well seemed tidier, but it merged bars in 9 tunes out of 400, and a
/// loop is picked by tapping bars on the page: lose a bar in the audio and the
/// loop points somewhere else entirely. That's what went wrong on the Lough
/// Gowna set. With no `:|` to send it back, an ending bracket is just a bracket
/// — bar 1 then bar 2, once each, in written order, which is what was wanted.
///
/// Measured over 599 tunes: 598 keep exactly the same bars, all 599 replay
/// nothing, 527 play shorter. The two in the library that still shift bars are
/// caught by the check at the point of use, not trusted to this.
function linearBody(body) {
  return (body || "")
    .replace(/::/g, "|")            // back-to-back repeat
    .replace(/\|\s*:/g, "|")        // |:  open
    .replace(/:\s*\|/g, "|");       // :|  close
}

// Make abcjs's transport safe to change speed on.
//
// `SynthController.setWarp` tears the synth down, rebuilds it, and then — if it
// was playing — starts it again. On the way it calls `control.setWarp`, which
// does this, with no guard:
//
//     r.parent.querySelector(".abcjs-midi-tempo").value = Math.round(t)
//
// We load the transport with `displayWarp: false`, because our own Slow/Fast
// row replaces abcjs's tempo box. So that element does not exist, the line
// throws, and the throw happens *before* the code that resumes playback. The
// result: every change of speed while playing destroys the audio and silently
// declines to restart it.
//
// That is the "TypeError: null is not an object (evaluating
// 'r.parent.querySelector(".abcjs-midi-tempo"' )" that has been sitting in the
// diagnostics panel for days. It is why the practice ramp increments once and
// stops, and why nudging the speed slider mid-tune could kill the sound.
//
// Replacing the method is better than re-enabling the box: the tempo readout
// is the only thing it was for, and `setTempo` guards its own lookup.
function ceolGuardTransport(synthControl) {
  var control = synthControl && synthControl.control;
  if (!control || control._ceolGuarded) return;
  control._ceolGuarded = true;
  control.setWarp = function (tempo) {
    try { control.setTempo(tempo); } catch (e) {}
  };
  // Same shape of problem, same treatment: setTune calls disable() first thing.
  var originalDisable = control.disable;
  control.disable = function (off) {
    try { originalDisable.call(control, off); } catch (e) {}
  };
  // Rewind while paused. abcjs moves the audio back to the start but only
  // redraws the progress dot as the music plays, so pressing ⏮ with the music
  // stopped appeared to do nothing (27 Oct 2026). The dot goes to the start
  // now, at once.
  var options = control.options;
  if (options && !options._ceolRewind) {
    options._ceolRewind = true;
    var originalRestart = options.restartHandler;
    options.restartHandler = function (arg) {
      var out = originalRestart ? originalRestart.apply(this, arguments) : undefined;
      ceolShowRewound(synthControl);
      return out;
    };
  }
}

/// Put the progress dot and clock at the start, and clear any lit notes, when
/// the music is not playing. While it plays, the audio clock moves them itself.
function ceolShowRewound(synthControl) {
  if (!synthControl || synthControl.isStarted) return;
  try { synthControl.setProgress(0, 0); } catch (e) {}
  if (typeof ceolAfterRewind === "function") {
    try { ceolAfterRewind(); } catch (e) {}
  }
}

// Handing the rendered audio to the app, so it can be played natively.
//
// abcjs renders the whole tune into an AudioBuffer before playback starts —
// that work is already done and paid for by the time the transport says it is
// ready. Playing it through the web view is what stops at the lock screen, so
// the buffer is passed to Swift and played with AVAudioPlayer instead: real
// background playback, lock-screen controls, and a rate control that changes
// speed without tearing the synth down.
//
// Mono at the context's own sample rate. Stereo doubles the transfer for no
// benefit — abcjs pans nothing by default — and an average set comes out around
// 10 MB rather than 22.
/// Why the last attempt to hand over the audio failed. A transfer that gives
/// up quietly is impossible to diagnose from the outside — every failure looks
/// identical from the page — so each exit says which one it was.
var ceolAudioError = "";

// FONN-CLEANSOUND-1
/// Bring the rendered performance down under full scale, evenly, if it goes
/// over. The samples are played at ×3 (CEOL_FONT_GAIN); melody, bass and
/// chords together often added up past 1.0, and what went past was cut off
/// flat — which is what made the flute sound fuzzy, worst on loud notes and
/// with the backing on. Scaling the whole thing by one factor keeps the
/// balance and the dynamics exactly as they were, just without the clipping.
/// Done in place, on abcjs's own buffer, so the Web Audio path (the Mac, and
/// the phone before the native player takes over) is cleaned too. Safe to
/// call more than once: the second time there is nothing over the line.
function ceolTameAudio(synthControl) {
  try {
    var buffer = synthControl && synthControl.midiBuffer && synthControl.midiBuffer.getAudioBuffer();
    if (!buffer || !buffer.length) return;
    var peak = 0, c, i, data;
    for (c = 0; c < buffer.numberOfChannels; c++) {
      data = buffer.getChannelData(c);
      for (i = 0; i < data.length; i++) {
        var a = data[i] < 0 ? -data[i] : data[i];
        if (a > peak) peak = a;
      }
    }
    var ceiling = 0.89;                   // about −1 dBFS
    if (peak <= ceiling) return;
    var k = ceiling / peak;
    for (c = 0; c < buffer.numberOfChannels; c++) {
      data = buffer.getChannelData(c);
      for (i = 0; i < data.length; i++) data[i] *= k;
    }
  } catch (e) {}
}

function ceolRenderedWav(synthControl) {
  ceolTameAudio(synthControl);
  var buffer = null;
  if (!synthControl) { ceolAudioError = "no transport"; return null; }
  if (!synthControl.midiBuffer) { ceolAudioError = "no midiBuffer"; return null; }
  try {
    buffer = synthControl.midiBuffer.getAudioBuffer();
  } catch (e) {
    ceolAudioError = "getAudioBuffer threw: " + (e && e.message ? e.message : e);
    return null;
  }
  if (!buffer) { ceolAudioError = "getAudioBuffer gave nothing"; return null; }
  if (!buffer.length) { ceolAudioError = "buffer has no frames"; return null; }

  var frames = buffer.length;
  var channels = buffer.numberOfChannels;
  var mixed = new Float32Array(frames);
  for (var c = 0; c < channels; c++) {
    var data = buffer.getChannelData(c);
    for (var i = 0; i < frames; i++) mixed[i] += data[i];
  }
  if (channels > 1) {
    for (var j = 0; j < frames; j++) mixed[j] /= channels;
  }

  var bytes = new ArrayBuffer(44 + frames * 2);
  var view = new DataView(bytes);
  var rate = buffer.sampleRate;
  function ascii(offset, text) {
    for (var k = 0; k < text.length; k++) view.setUint8(offset + k, text.charCodeAt(k));
  }
  ascii(0, "RIFF");
  view.setUint32(4, 36 + frames * 2, true);
  ascii(8, "WAVEfmt ");
  view.setUint32(16, 16, true);          // PCM header length
  view.setUint16(20, 1, true);           // uncompressed
  view.setUint16(22, 1, true);           // mono
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * 2, true);    // bytes per second
  view.setUint16(32, 2, true);           // bytes per frame
  view.setUint16(34, 16, true);          // bits per sample
  ascii(36, "data");
  view.setUint32(40, frames * 2, true);
  for (var n = 0; n < frames; n++) {
    var sample = Math.max(-1, Math.min(1, mixed[n]));
    view.setInt16(44 + n * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
  }
  return { bytes: bytes, sampleRate: rate, seconds: frames / rate };
}

/// Send it across in pieces. One 10 MB string through the message bridge is
/// slow and hungry; chunks keep the memory flat and let the app show progress.
function ceolSendRenderedAudio(synthControl, token) {
  ceolAudioError = "";
  var channel;
  try {
    channel = window.webkit.messageHandlers.audio;
  } catch (e) { channel = null; }
  if (!channel) { ceolAudioError = "no audio channel to the app"; return false; }

  var wav = ceolRenderedWav(synthControl);
  if (!wav) {
    try { channel.postMessage({ kind: "failed", token: token }); } catch (e) {}
    return false;
  }

  var whole = new Uint8Array(wav.bytes);
  // 128 KB rather than 512. A message is copied and bridged whole, and the
  // larger it is the more likely it is to be refused or to stall; smaller
  // pieces cost a few more messages and are far more reliable.
  var CHUNK = 128 * 1024;
  var total = Math.ceil(whole.length / CHUNK);
  var sent = 0;
  try {
    channel.postMessage({
      kind: "begin", token: token, chunks: total,
      bytes: whole.length, seconds: wav.seconds,
    });
    for (var index = 0; index < total; index++) {
      var slice = whole.subarray(index * CHUNK, Math.min((index + 1) * CHUNK, whole.length));
      // Base64 in pieces: btoa on a 10 MB string is what makes this slow, and
      // building the argument string a chunk at a time keeps it bearable.
      var binary = "";
      for (var b = 0; b < slice.length; b += 8192) {
        binary += String.fromCharCode.apply(null, slice.subarray(b, b + 8192));
      }
      channel.postMessage({
        kind: "chunk", token: token, index: index, data: btoa(binary),
      });
      sent++;
    }
    channel.postMessage({ kind: "end", token: token });
    return true;
  } catch (e) {
    ceolAudioError = "stopped after " + sent + " of " + total + " pieces: "
      + (e && e.message ? e.message : e);
    return false;
  }
}

// Picking playback up again after the screen has slept.
//
// Apple Music keeps going because it plays through the native audio stack. The
// music here is generated by Web Audio inside a web view, and iOS suspends that
// when the screen locks — often destroying the audio device outright, which is
// the "InvalidStateError: Failed to start the audio device" the panel reports
// on waking. The audio background mode keeps the app alive but does not save
// the web view's audio graph.
//
// So: remember where playback was, and start it again from there when the
// screen comes back. If the device really has gone, `rebuild` is called to
// re-prime the synth from scratch before trying once more.
function ceolWatchForWake(getSynth, rebuild) {
  var wasPlaying = false;
  var percent = 0;

  function remember() {
    var synth = getSynth();
    if (!synth) return;
    wasPlaying = !!synth.isStarted;
    percent = synth.percent || 0;
  }

  function contextRunning() {
    try {
      var ctx = ABCJS.synth.activeAudioContext && ABCJS.synth.activeAudioContext();
      return !!ctx && ctx.state === "running";
    } catch (e) { return false; }
  }

  function seekBack(synth) {
    if (!percent) return;
    try { synth.seek(percent); } catch (e) {}
  }

  function attempt(rebuilt) {
    var synth = getSynth();
    if (!synth) return;
    try {
      if (!synth.isStarted) {
        var promise = synth.play();
        if (promise && promise.catch) promise.catch(function () { recover(rebuilt); });
      }
    } catch (e) { recover(rebuilt); return; }
    // Give it a moment, then check it really started. A play() that resolves
    // while the context is still dead is the failure mode worth catching.
    setTimeout(function () {
      var s = getSynth();
      if (!s) return;
      if (s.isStarted && contextRunning()) seekBack(s);
      else recover(rebuilt);
    }, 400);
  }

  function recover(alreadyRebuilt) {
    if (alreadyRebuilt || typeof rebuild !== "function") return;
    // The audio device was lost. Build it again, then resume where we were.
    rebuild(function () {
      var synth = getSynth();
      if (!synth) return;
      seekBack(synth);
      try { if (!synth.isStarted) synth.play(); } catch (e) {}
    });
  }

  function wake() {
    try {
      var ctx = ABCJS.synth.activeAudioContext && ABCJS.synth.activeAudioContext();
      if (ctx && ctx.state !== "running" && ctx.resume) ctx.resume();
    } catch (e) {}
    if (!wasPlaying) return;
    wasPlaying = false;
    setTimeout(function () { attempt(false); }, 200);
  }

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) remember(); else wake();
  });
  window.addEventListener("pagehide", remember);
  window.addEventListener("pageshow", wake);
  window.addEventListener("focus", wake);
}

/// Change the speed and do something once the synth has actually been rebuilt.
///
/// setWarp is asynchronous — it re-primes the audio — so anything that depends
/// on the new timing has to wait for its promise rather than guess at a delay.
function ceolSetWarp(synthControl, percent, then) {
  if (!synthControl) { if (then) then(); return; }
  // Already there? Then do nothing at all.
  //
  // setWarp is not a cheap setter: it calls destroy(), which throws the audio
  // buffer away, and rebuilds it asynchronously. Calling it with the speed it
  // is already at — which happens on every render, because applySpeed runs
  // when priming finishes — meant the freshly built audio was demolished the
  // instant it existed. Anything reading the buffer just after priming found
  // an empty one.
  if (synthControl.warp === percent) { if (then) then(); return; }
  ceolGuardTransport(synthControl);
  var promise;
  try {
    promise = synthControl.setWarp(percent);
  } catch (e) {
    if (then) then();
    return;
  }
  if (promise && promise.then) {
    promise.then(function () { if (then) then(); })
           .catch(function () { if (then) then(); });
  } else if (then) {
    then();
  }
}

function linearABC(abc) {
  var k = (abc || "").match(/^K:[^\n]*/m);
  if (!k) return abc;
  var cut = abc.indexOf(k[0]) + k[0].length;
  return abc.slice(0, cut) + linearBody(abc.slice(cut));
}

/// Join a closing repeat to the opening repeat that follows it.
///
/// ABC lets you write the end of one section and the start of the next as two
/// separate barlines — ":|" then "|:" — and 234 of the tunes in the library do.
/// abcjs renders that faithfully as two barlines (bar_right_repeat then
/// bar_left_repeat), and when the line wraps between them the opening one is
/// left stranded on the end of the previous line, after the closing dots and
/// before any music. It looks wrong because it is wrong: engraving convention
/// is one barline carrying dots on both sides.
///
/// "::" is exactly that barline, and abcjs draws it as bar_dbl_repeat. The two
/// forms are identical in meaning, so the audio and the note timings do not
/// change — only the number of barlines drawn, which goes from two to one.
///
/// Display only. The stored ABC is left as its author wrote it.
function ceolTidyRepeats(abc) {
  if (!abc) return abc;
  // Any run of whitespace or newlines between them, but nothing else.
  return abc.replace(/:\|\s*\|:/g, "::");
}

/// Shared machinery behind ceolTidyRepeatsMapped and stripDisplayHeadersMapped
/// (abc.html): build the transformed text the same way `source.replace(re,
/// ...)` would, but also a `mapBack(offset)` that turns an offset into that
/// text back into the corresponding offset in `source`.
///
/// Needed because abcjs's click and bar offsets are always relative to
/// whatever string was actually handed to ABCJS.renderAbc — and by the time a
/// tune reaches the page, that is neither the ABC the tune was saved with
/// (ceolTidyRepeats already folded ":| |:" into "::") nor even that
/// (stripDisplayHeaders already took the header lines back out). Undoing both,
/// in the order they were applied, is the only way a click on the sheet music
/// can land back on the right character of what's actually stored.
///
/// An offset that lands INSIDE a replaced span — the "::" that stood in for
/// ":| |:", say — has no exact original counterpart, so it snaps to where
/// that span began in `source`.
function ceolBuildOffsetMap(source, re, replacement) {
  var text = "";
  var ranges = []; // {newStart, newEnd, origStart, origEnd}, in order
  var last = 0;
  var m;
  while ((m = re.exec(source))) {
    var origStart = m.index, origEnd = m.index + m[0].length;
    text += source.slice(last, origStart);
    var newStart = text.length;
    text += replacement(m[0]);
    ranges.push({ newStart: newStart, newEnd: text.length, origStart: origStart, origEnd: origEnd });
    last = origEnd;
    // A pattern that can match zero characters would otherwise spin here
    // forever. Neither regex this feeds ever does, but the guard is cheap.
    if (m[0].length === 0) re.lastIndex++;
  }
  text += source.slice(last);

  function mapBack(n) {
    if (typeof n !== "number") return n;
    var delta = 0;
    for (var i = 0; i < ranges.length; i++) {
      var r = ranges[i];
      if (n <= r.newStart) return n + delta;
      if (n <= r.newEnd) return r.origStart;
      delta += (r.origEnd - r.origStart) - (r.newEnd - r.newStart);
    }
    return n + delta;
  }

  return { text: text, mapBack: mapBack };
}

/// ceolTidyRepeats, but returning the offset map alongside the text so a
/// click reported against the tidied string can be traced back to the ABC as
/// the tune actually stores it.
function ceolTidyRepeatsMapped(abc) {
  if (!abc) return { text: abc, mapBack: function (n) { return n; } };
  // FONN-SPLITREPEAT-1: on one line only. Across a line break the :| ends
  // one part and the |: opens the next, and joined they hung off the end.
  return ceolBuildOffsetMap(abc, /:\|[ \t]*\|:/g, function () { return "::"; });
}

// FONN-TEMPO-1 ---------------------------------------------------------------
// How fast a tune goes, and how its bar is counted, when the notation doesn't
// say. Mirrors CeolCore/Audio/TuneTypeDefaults.swift; keep the two in step.
//
// Nine tunes in ten carry no Q:, and abcjs then plays everything at 180 a beat
// (120 in 6/8, 9/8, 12/8): a waltz, a strathspey and a reel all at the same
// speed. The tune's type gives a sensible one instead.
//
// Reels, hornpipes, strathspeys, barndances and their kin are counted two to
// the bar, the way a foot taps them, so the number reads as a player would
// say it and tapping along to a recording gives the same number back.
// Tempos are in the beats counted: minims for those, dotted crotchets in
// compound time, crotchets otherwise.
var CEOL_TYPE_TEMPO = {
  "reel": 90, "shetland reel": 90,
  "jig": 100, "double jig": 100, "slip jig": 100, "single jig": 105, "hop jig": 100,
  "slide": 115, "hornpipe": 70, "polka": 130, "waltz": 140, "vals": 140,
  "mazurka": 130, "barndance": 75, "barn dance": 75, "fling": 70,
  "highland": 70, "strathspey": 60, "march": 100, "pipe march": 90,
  "three-two": 120, "schottische": 70, "air": 70, "slow air": 70, "song air": 70
};
var CEOL_IN_TWO = ["reel", "shetland reel", "hornpipe", "strathspey", "barndance",
                   "barn dance", "fling", "highland", "schottische"];

function ceolTypeKey(abc, type) {
  var t = (type || "").trim().toLowerCase();
  if (!t) t = ((((abc || "").match(/^R:\s*(.+)$/m) || [])[1]) || "").trim().toLowerCase();
  if (!t) return "";
  if (CEOL_TYPE_TEMPO.hasOwnProperty(t)) return t;
  var simple = t.slice(-1) === "s" ? t.slice(0, -1) : t;
  if (CEOL_TYPE_TEMPO.hasOwnProperty(simple)) return simple;
  var best = "";
  Object.keys(CEOL_TYPE_TEMPO).forEach(function (k) {
    if (t.indexOf(k) === 0 && k.length > best.length) best = k;
  });
  return best;
}

/// The time signature as it is counted: the written one, except that a reel
/// and its kin in 4/4 are counted as 2/2.
function ceolCountingMeter(abc, type) {
  var m = (((abc || "").match(/^M:\s*(\S+)/m) || [])[1]) || "4/4";
  if ((m === "4/4" || m === "C") && CEOL_IN_TWO.indexOf(ceolTypeKey(abc, type)) >= 0) return "2/2";
  return m;
}

/// Beats in a bar as a player counts them: two in 6/8 and in a reel.
function ceolBeatsPerBar(meter) {
  if (meter === "C") return 4;
  if (meter === "C|") return 2;
  var parts = (meter || "").split("/");
  var top = parseInt(parts[0], 10), bottom = parseInt(parts[1], 10);
  if (!top || !bottom) return 4;
  if (bottom === 8 && top % 3 === 0) return top / 3;
  return top;
}

/// The tempo to play a tune at when it has no Q:, as abcjs holds a tempo
/// ({ duration: [beat length], bpm }), or null to leave abcjs's own.
function ceolDefaultTempo(abc, type) {
  if (/^Q:/m.test(abc || "")) return null;
  var key = ceolTypeKey(abc, type);
  if (!key) return null;
  var meter = ceolCountingMeter(abc, type);
  if (meter === "C") meter = "4/4";
  if (meter === "C|") meter = "2/2";
  var parts = meter.split("/");
  var top = parseInt(parts[0], 10), bottom = parseInt(parts[1], 10);
  if (!top || !bottom) return null;
  var beat = (bottom === 8 && top % 3 === 0) ? 3 / 8 : 1 / bottom;
  return { duration: [beat], bpm: CEOL_TYPE_TEMPO[key] };
}

/// FONN-SNIPSTD-1. A standard speed in crotchets a minute, whatever the tune
/// says: its type's speed, or for a tune with no type a moderate one for its
/// time signature. For snippets, which are for recognising a tune, so a tune
/// with no type or a stray Q: (Q:200 with L:1/16, say) mustn't gallop.
var CEOL_METER_TEMPO = {     // beat length -> beats a minute, for untyped tunes
  "1/2": 80, "1/4": 110, "3/8": 100, "1/8": 200
};
function ceolStandardQpm(abc, type) {
  var key = ceolTypeKey(abc, type);
  var meter = ceolCountingMeter(abc, type);
  if (meter === "C") meter = "4/4";
  if (meter === "C|") meter = "2/2";
  var parts = meter.split("/");
  var top = parseInt(parts[0], 10), bottom = parseInt(parts[1], 10);
  if (!top || !bottom) { top = 4; bottom = 4; }
  var beat = (bottom === 8 && top % 3 === 0) ? 3 / 8 : 1 / bottom;
  var bpm = key ? CEOL_TYPE_TEMPO[key]
                : CEOL_METER_TEMPO[beat === 3 / 8 ? "3/8" : "1/" + bottom] || 110;
  return Math.round(bpm * 4 * beat);
}

/// The same, as the text of a Q: field, for ABC that is built rather than
/// rendered straight (a set's joined-up tune).
function ceolDefaultQ(abc, type) {
  var t = ceolDefaultTempo(abc, type);
  if (!t) return "";
  var d = t.duration[0];
  var frac = d === 3 / 8 ? "3/8" : "1/" + Math.round(1 / d);
  return frac + "=" + t.bpm;
}

/// Give a rendered tune its default tempo, if it has none of its own.
function ceolApplyDefaultTempo(visual, abc, type) {
  if (!visual) return;
  var t = ceolDefaultTempo(abc, type);
  if (!t) return;
  visual.metaText = visual.metaText || {};
  if (!visual.metaText.tempo) visual.metaText.tempo = t;
}

// FONN-ABCFOLLOW-1 -----------------------------------------------------------
// The bars as played, for the metronome to click with the tune's own beats.

/// Clicks to a beat when a bar of `meter` is counted out: three in compound
/// time, one otherwise.
function ceolBeatSub(meter) {
  var p = (meter || "").split("/");
  var top = parseInt(p[0], 10), bottom = parseInt(p[1], 10);
  return (bottom === 8 && top % 3 === 0) ? 3 : 1;
}

/// From abcjs's note timings (playing order: repeats, endings, a set's tunes
/// in turn): each bar as [startMs, fullBarMs, beats, sub], and when the music
/// ends. `countFor(event)` gives { beats, sub, seg } for the bar an event
/// begins; `seg` separates a set's tunes, whose bars are different lengths.
///
/// A full bar's length is measured, not asked for: the commonest bar length in
/// each tune. abcjs's own figure ignores tempo changes inside a set.
function ceolBarsFromTimings(events, countFor) {
  var starts = [], endMs = 0;
  (events || []).forEach(function (ev) {
    if (!ev || typeof ev.milliseconds !== "number") return;
    if (ev.milliseconds > endMs) endMs = ev.milliseconds;
    if (!ev.measureStart || ev.type === "end") return;
    if (starts.length && Math.abs(starts[starts.length - 1].ms - ev.milliseconds) < 1) return;
    var c = countFor(ev) || {};
    starts.push({ ms: ev.milliseconds, beats: c.beats || 4, sub: c.sub || 1, seg: c.seg || 0 });
  });
  var counts = {};
  starts.forEach(function (s, i) {
    var next = i + 1 < starts.length ? starts[i + 1].ms : endMs;
    var dur = Math.round((next - s.ms) / 5) * 5;
    if (dur <= 0) return;
    var seg = counts[s.seg] || (counts[s.seg] = {});
    var bucket = seg[dur] || (seg[dur] = { n: 0, sum: 0 });
    bucket.n += 1;
    bucket.sum += next - s.ms;
  });
  var full = {};
  Object.keys(counts).forEach(function (seg) {
    var best = 0, bestN = 0, bestMean = 0;
    Object.keys(counts[seg]).forEach(function (d) {
      var b = counts[seg][d], dur = +d;
      if (b.n > bestN || (b.n === bestN && dur > best)) { best = dur; bestN = b.n; bestMean = b.sum / b.n; }
    });
    full[seg] = Math.round(bestMean * 1000) / 1000;
  });
  var bars = [];
  starts.forEach(function (s) {
    var f = full[s.seg];
    if (f > 0) bars.push([Math.round(s.ms * 10) / 10, f, s.beats, s.sub]);
  });
  return { bars: bars, end: Math.round(endMs) };
}

// FONN-CHORDDRONE-1: the chords as played, for the drone to follow.
// Each change as [ms, interval]: the chord's root in semitones above the
// tune's home note, both read from the same render, so a transposition
// (which abcjs applies to the key and the chord symbols alike, or to
// neither) cannot put them out of step. Chord symbols only ("D", "Em7",
// "G/B"), not text annotations; the chords Fonn suggests for a tune with
// none count, as they are in the ABC that is played.
function ceolChordRoot(name) {
  var m = /^\s*([A-Ga-g])([#b♯♭]?)/.exec(name || "");
  if (!m) return null;
  var pc = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }[m[1].toUpperCase()];
  if (m[2] === "#" || m[2] === "♯") pc += 1;
  if (m[2] === "b" || m[2] === "♭") pc -= 1;
  return (pc + 12) % 12;
}

function ceolKeyRoot(obj) {
  try {
    var k = obj.getKeySignature();
    if (!k || !k.root || k.root === "none") return null;
    var acc = k.acc === "#" || k.acc === "sharp" ? "#" : (k.acc === "b" || k.acc === "flat" ? "b" : "");
    if (k.root === "HP" || k.root === "Hp") return 9;
    return ceolChordRoot(k.root + acc);
  } catch (e) { return null; }
}

function ceolChordsFromTimings(events, obj) {
  if (!obj || typeof obj.getElementFromChar !== "function") return [];
  var home = ceolKeyRoot(obj);
  if (home === null) return [];
  var out = [], last = null;
  (events || []).forEach(function (ev) {
    if (!ev || typeof ev.milliseconds !== "number" || typeof ev.startChar !== "number") return;
    var el = null;
    try { el = obj.getElementFromChar(ev.startChar); } catch (e) {}
    if (!el || !el.chord || !el.chord.length) return;
    for (var i = 0; i < el.chord.length; i++) {
      var c = el.chord[i];
      if (c.position && c.position !== "default") continue;
      var root = ceolChordRoot(c.name);
      if (root === null) continue;
      var interval = (root - home + 12) % 12;
      if (interval !== last) { out.push([Math.round(ev.milliseconds), interval]); last = interval; }
      break;
    }
  });
  return out;
}

/// Where abcjs's own audio is, in ms of its timings. Its timer runs 16 ms
/// ahead of the sound on purpose (to light notes in time); this takes it off.
function ceolTimerMs(synthControl) {
  try {
    var ms = synthControl.timer.currentMillisecond();
    return typeof ms === "number" && isFinite(ms) ? Math.max(0, ms - 16) : null;
  } catch (e) { return null; }
}
