// FONN-SHEETMODE-1
// Sheet music mode: Fonn as a music stand. Shared by abc.html (one tune) and
// set.html (a set), on the phone, the iPad and the Mac.
//
// In this mode the page is only the music: no play controls, and a tap on a
// bar no longer starts playback or a loop. You can zoom in by pinching (or ⌘+
// and ⌘− on the Mac, from the app) and scroll up and down by hand. The app
// adds a bar under the music with the metronome and Scroll.
//
// Scroll moves the music up the page **in time with the metronome**, not at so
// many seconds a line as Òrain's does for words. The page knows where each line
// of music is and how many bars are on it, so a line of four bars at 120 bpm in
// 2/4 takes four seconds, and change the tempo and the scroll follows. A speed
// of its own (Slower / Faster in the app) is a multiplier on top of that, for
// when you want to read ahead or are being left behind.
//
// Repeats. The scroll can't jump back up the page for a repeat (a reader's eye
// can; a page that leapt about would be impossible to follow), so the time a
// tune takes, repeats and all, is spread evenly over its bars. For the usual
// AABB tune that means the scroll moves at half the plain speed and arrives at
// the B part exactly when you do. In a set, each tune's own time is also
// multiplied by its ×1/×2/×3, so the scroll is at the next tune when you are.
//
// The page supplies `ceolScrollSections()`: for each tune shown, the element
// its music is drawn in, beats in a bar, how much longer than one plain pass
// its repeats make it, and how many times through.

var ceolSheet = {
  on: false,
  zoom: 1,
  scrolling: false,
  bpm: 100,
  factor: 1,
  t: 0,          // ms into the music at the plain tempo
  keys: [],      // [{t, y}] where each line starts, in scroll coordinates
  raf: 0,
  last: 0,
  handAt: 0,     // when the reader last moved the page by hand
  pinchFrom: 1
};

function ceolSheetScroller() { return document.getElementById("scroller"); }

function ceolSheetPost(msg) {
  try { window.webkit.messageHandlers.sheet.postMessage(msg); } catch (e) {}
}

// MARK: Mode

/// On or off, from the app.
function ceolSheetMode(on) {
  on = !!on;
  if (on === ceolSheet.on) return;
  ceolSheet.on = on;
  document.documentElement.classList.toggle("ceol-sheet", on);
  if (!on) {
    ceolSheetScroll(false);
    ceolSheetZoom(1);
  }
}

// MARK: Zoom

/// Zoom the music, 1 being the size it is drawn at. Each SVG keeps its
/// proportions (its viewBox), so the bar map and tap targets, which work in the
/// SVG's own units, are untouched. Wider than the screen, it scrolls sideways.
function ceolSheetZoom(z) {
  z = Math.max(0.5, Math.min(3, +z || 1));
  var scroller = ceolSheetScroller();
  var old = ceolSheet.zoom;
  ceolSheet.zoom = z;
  ceolSheetApplyZoom();
  // Stay on the same music rather than the same pixel.
  if (scroller && old > 0 && z !== old) scroller.scrollTop = scroller.scrollTop * (z / old);
  ceolSheetRebuild();
}

function ceolSheetApplyZoom() {
  var z = ceolSheet.zoom;
  ceolSheetSvgs().forEach(function (svg) {
    if (z === 1) {
      svg.style.removeProperty("width");
      svg.style.removeProperty("max-width");
    } else {
      svg.style.width = (z * 100).toFixed(1) + "%";
      svg.style.maxWidth = "none";
    }
  });
}

function ceolSheetSvgs() {
  var out = [];
  (typeof ceolScrollSections === "function" ? ceolScrollSections() : []).forEach(function (s) {
    if (s.container) out = out.concat(Array.prototype.slice.call(s.container.querySelectorAll("svg")));
  });
  return out;
}

/// After the page redraws the music (a resize, a new size), the SVGs are new.
function ceolSheetAfterRender() {
  if (ceolSheet.zoom !== 1) ceolSheetApplyZoom();
  ceolSheetRebuild();
}

// Pinch, on the phone and iPad, and on a Mac trackpad: WebKit's gesture
// events. The page itself never zooms (the viewport forbids it, which keeps
// everything else on it working); this zooms the music.
document.addEventListener("gesturestart", function (e) {
  if (!ceolSheet.on) return;
  e.preventDefault();
  ceolSheet.pinchFrom = ceolSheet.zoom;
}, { passive: false });
document.addEventListener("gesturechange", function (e) {
  if (!ceolSheet.on) return;
  e.preventDefault();
  ceolSheetZoom(ceolSheet.pinchFrom * e.scale);
}, { passive: false });
document.addEventListener("gestureend", function (e) {
  if (!ceolSheet.on) return;
  e.preventDefault();
  ceolSheetPost({ zoom: ceolSheet.zoom });
}, { passive: false });

// A tap on the music does nothing here: no playback starts, no loop is set.
// Buttons (a set's ×2 repeats, its tune names) still work.
document.addEventListener("click", function (e) {
  if (!ceolSheet.on) return;
  if (e.target && e.target.closest && e.target.closest("svg")) {
    e.stopPropagation();
    e.preventDefault();
  }
}, true);

// MARK: Scroll

/// Start or stop scrolling. `bpm` is the metronome's tempo; `factor` the
/// reader's own Slower / Faster on top (1 = in time).
function ceolSheetScroll(on, bpm, factor) {
  if (bpm) ceolSheet.bpm = bpm;
  if (factor) ceolSheet.factor = factor;
  on = !!on;
  if (on && !ceolSheet.scrolling) {
    ceolSheetRebuild();
    if (ceolSheet.keys.length < 2) { ceolSheetPost({ scrolling: false }); return; }
    // From what is on screen now, not from the top.
    ceolSheet.t = ceolSheetTimeAt(ceolSheetScroller().scrollTop + ceolSheetLead());
    ceolSheet.scrolling = true;
    ceolSheet.last = performance.now();
    ceolSheet.raf = requestAnimationFrame(ceolSheetFrame);
  } else if (!on && ceolSheet.scrolling) {
    ceolSheet.scrolling = false;
    cancelAnimationFrame(ceolSheet.raf);
  }
}

/// Tempo or speed changed while scrolling: carry on from the same place.
function ceolSheetScrollRate(bpm, factor) {
  var here = ceolSheet.scrolling ? ceolSheet.t : null;
  if (bpm) ceolSheet.bpm = bpm;
  if (factor) ceolSheet.factor = factor;
  // Positions are in plain-tempo time, so a new tempo needs new keys.
  ceolSheetRebuild();
  if (here !== null) ceolSheet.t = Math.min(here, ceolSheetEnd());
}

/// How far down the screen the line being played sits: a quarter of the way,
/// so the line after it is already in view.
function ceolSheetLead() {
  var s = ceolSheetScroller();
  return s ? s.clientHeight * 0.25 : 0;
}

/// Where each line of music starts, and when it is reached.
function ceolSheetRebuild() {
  var keepY = null;
  var scroller = ceolSheetScroller();
  if (!scroller) return;
  if (ceolSheet.scrolling && ceolSheet.keys.length) keepY = ceolSheetYAt(ceolSheet.t);
  var top0 = scroller.getBoundingClientRect().top - scroller.scrollTop;
  var keys = [];
  var t = 0, lastBottom = 0;
  var sections = typeof ceolScrollSections === "function" ? ceolScrollSections() : [];
  sections.forEach(function (sec) {
    if (!sec.container) return;
    var bars = typeof buildBarMapIn === "function" ? buildBarMapIn(sec.container) : [];
    var per = new Map();
    bars.forEach(function (b) { per.set(b.wrapper, (per.get(b.wrapper) || 0) + 1); });
    // One bar, in ms, at the metronome's tempo, with this tune's repeats and
    // times through spread over it (see the top of this file).
    var beats = sec.beats || 4;
    var msPerBar = beats * 60000 / Math.max(20, ceolSheet.bpm)
      * Math.max(1, sec.repeatFactor || 1) * Math.max(1, sec.times || 1);
    sec.container.querySelectorAll(".abcjs-staff-wrapper").forEach(function (w) {
      var r = w.getBoundingClientRect();
      if (!r.height) return;
      keys.push({ t: t, y: r.top - top0 });
      t += (per.get(w) || 0) * msPerBar;
      lastBottom = r.bottom - top0;
    });
  });
  if (keys.length) keys.push({ t: t, y: lastBottom });
  ceolSheet.keys = keys;
  if (keepY !== null) ceolSheet.t = ceolSheetTimeAt(keepY);
}

function ceolSheetEnd() {
  var k = ceolSheet.keys;
  return k.length ? k[k.length - 1].t : 0;
}

function ceolSheetYAt(t) {
  var k = ceolSheet.keys;
  if (!k.length) return 0;
  if (t <= k[0].t) return k[0].y;
  for (var i = 1; i < k.length; i++) {
    if (t <= k[i].t) {
      var span = k[i].t - k[i - 1].t;
      var f = span > 0 ? (t - k[i - 1].t) / span : 1;
      return k[i - 1].y + (k[i].y - k[i - 1].y) * f;
    }
  }
  return k[k.length - 1].y;
}

function ceolSheetTimeAt(y) {
  var k = ceolSheet.keys;
  if (!k.length) return 0;
  if (y <= k[0].y) return k[0].t;
  for (var i = 1; i < k.length; i++) {
    if (y <= k[i].y) {
      var span = k[i].y - k[i - 1].y;
      var f = span > 0 ? (y - k[i - 1].y) / span : 1;
      return k[i - 1].t + (k[i].t - k[i - 1].t) * f;
    }
  }
  return k[k.length - 1].t;
}

// Moving the page by hand while it scrolls: it lets go while your finger is
// on it, then carries on from wherever you left it.
// Loaded in the page's <head>, before the scroller exists.
document.addEventListener("DOMContentLoaded", function () {
  var s = ceolSheetScroller();
  if (!s) return;
  ["touchmove", "wheel"].forEach(function (evt) {
    s.addEventListener(evt, function () { ceolSheet.handAt = performance.now(); }, { passive: true });
  });
});

function ceolSheetFrame(now) {
  if (!ceolSheet.scrolling) return;
  var scroller = ceolSheetScroller();
  var dt = Math.min(250, now - ceolSheet.last);
  ceolSheet.last = now;
  if (now - ceolSheet.handAt < 1200) {
    // The reader has it: follow them.
    ceolSheet.t = ceolSheetTimeAt(scroller.scrollTop + ceolSheetLead());
  } else {
    ceolSheet.t += dt * ceolSheet.factor;
    // Mark it as the page's own scroll, so the app's header doesn't treat it
    // as the reader scrolling (see abc.html / set.html).
    if (typeof lastFollowAt !== "undefined") lastFollowAt = Date.now();
    if (typeof lastScrollAt !== "undefined") lastScrollAt = Date.now();
    var target = Math.max(0, ceolSheetYAt(ceolSheet.t) - ceolSheetLead());
    scroller.scrollTop = target;
  }
  var max = scroller.scrollHeight - scroller.clientHeight;
  if (ceolSheet.t >= ceolSheetEnd() || (scroller.scrollTop >= max - 1 && ceolSheet.t > 0 && now - ceolSheet.handAt >= 1200 && ceolSheetYAt(ceolSheet.t) - ceolSheetLead() >= max)) {
    // The end of the music: stop, and say so.
    ceolSheet.scrolling = false;
    ceolSheetPost({ scrolling: false });
    return;
  }
  ceolSheet.raf = requestAnimationFrame(ceolSheetFrame);
}
