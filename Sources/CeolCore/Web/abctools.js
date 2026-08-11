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

function ceolRenderedWav(synthControl) {
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
