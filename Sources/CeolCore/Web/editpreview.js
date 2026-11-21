// FONN-COMPOSE-1: hearing what is on the page, for the three new editors.
// The same steps as noteedit.html's preview: wait for the soundfont check,
// play the engraving that is on screen, and light each note as it sounds.
var ceolPrev = { synth: null, timer: null, on: false, button: null, host: null };

function ceolPreviewClear() {
  if (!ceolPrev.host) return;
  var lit = ceolPrev.host.querySelectorAll(".ceol-playing");
  for (var i = 0; i < lit.length; i++) lit[i].classList.remove("ceol-playing");
}

function ceolPreviewSync() {
  var b = ceolPrev.button;
  if (!b) return;
  b.innerHTML = ceolPrev.on ? "&#9632;" : "&#9654;";
  b.classList.toggle("on", ceolPrev.on);
}

function ceolPreviewStop() {
  ceolPrev.on = false;
  if (ceolPrev.timer) { try { ceolPrev.timer.stop(); } catch (e) {} }
  if (ceolPrev.synth) { try { ceolPrev.synth.stop(); } catch (e) {} }
  ceolPreviewClear();
  ceolPreviewSync();
}

function ceolPreviewStart(visual, host, extra) {
  if (!visual || !ABCJS.synth.supportsAudio()) return;
  ceolPrev.host = host;
  ceolPrev.on = true;
  ceolPreviewSync();
  ceolWhenFontReady(function () {
    if (!ceolPrev.on) return;
    if (ceolPrev.synth) { try { ceolPrev.synth.stop(); } catch (e) {} }
    ceolPrev.synth = new ABCJS.synth.CreateSynth();
    var options = audioParams(visual);
    for (var k in (extra || {})) options[k] = extra[k];
    ceolPrev.synth.init({ visualObj: visual, options: options })
      .then(function () { return ceolPrev.synth.prime(); })
      .then(function () {
        if (!ceolPrev.on) { try { ceolPrev.synth.stop(); } catch (e) {} return; }
        ceolPrev.synth.start();
        try {
          ceolPrev.timer = new ABCJS.TimingCallbacks(visual, {
            eventCallback: function (ev) {
              ceolPreviewClear();
              if (!ev) { ceolPreviewStop(); return null; }
              (ev.elements || []).forEach(function (group) {
                (group || []).forEach(function (el) { if (el && el.classList) el.classList.add("ceol-playing"); });
              });
            }
          });
          ceolPrev.timer.start();
        } catch (e) {}
      })
      .catch(function () { ceolPrev.on = false; ceolPreviewSync(); });
  });
}

/// The abcjs element drawn for each note, by the character it starts at.
function ceolElementsByStart(visual) {
  var map = {};
  ((visual && visual.lines) || []).forEach(function (line) {
    ((line && line.staff) || []).forEach(function (staff) {
      ((staff && staff.voices) || []).forEach(function (voice) {
        (voice || []).forEach(function (el) {
          if (el && el.el_type === "note" && typeof el.startChar === "number") map[el.startChar] = el;
        });
      });
    });
  });
  return map;
}

/// Lay the music out to fit, the way noteedit.html does (padding taken off
/// the width, the container cleared first so it doesn't shrink each time).
function ceolRenderInto(host, abc, zoom, opts) {
  host.innerHTML = "";
  var pad = 32;
  try {
    var cs = window.getComputedStyle(host);
    pad = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
  } catch (e) {}
  var avail = Math.max(240, host.clientWidth - pad - 8);
  var perLine = Math.max(1, Math.round((window.innerWidth > 700 ? 4 : 3) / zoom));
  var o = {
    add_classes: true, staffwidth: Math.round(avail / zoom), scale: zoom,
    wrap: { preferredMeasuresPerLine: perLine },
    paddingtop: 8, paddingbottom: 8, paddingleft: 12, paddingright: 12
  };
  for (var k in (opts || {})) o[k] = opts[k];
  try { return (ABCJS.renderAbc(host, abc, o) || [])[0] || null; } catch (e) { return null; }
}

function ceolPostDirty(dirty) {
  try { window.webkit.messageHandlers.noteedit.postMessage({ dirty: !!dirty }); } catch (e) {}
}
