// FONN-MARKS-1
// A highlighter for the music. Shared by abc.html (one tune) and set.html (a
// set), on the phone, the iPad and the Mac, in the ordinary view and in Sheet
// music mode alike.
//
// What a mark is. Not a place on the page: a run of notes, "from the 12th note
// of this tune to the 30th", and a colour. The page is redrawn all the time —
// a different size, a transposition, the phone turned round, the whole tune
// fitted to the screen — and a mark that was so many pixels from the corner
// would be left hanging over the wrong bar. Counting notes, it lands on the
// same music every time, and it is the same on every device the tune syncs to.
// (Rests count as notes. Chord symbols and bar lines don't, so Fonn's own
// suggested chords coming and going moves nothing.)
//
// How it's drawn. A band the height of the stave, behind the notes, from the
// first note to the last; a mark that runs over the end of a line carries on
// from the start of the next, as a highlighter pen would. The bands are part
// of each line's own drawing (its SVG), so zooming and fitting scale them with
// the music for nothing.
//
// How you mark. Turn the highlighter on with the button at the bottom right of
// the music, pick a colour, then either drag along the notes, or tap the first
// note and then the last (which is the way across several lines on a phone,
// where dragging down the page scrolls it). The rubber takes out what you drag
// over, or the whole mark you tap. While the highlighter is on, a tap on the
// music does nothing else: no playback, no loop.
//
// Keeping them. Every change is handed to the app (the "marks" channel), which
// stores it on the tune; the app hands the marks back through ceolSetMarks
// whenever it shows a tune. Nothing is kept in the page.

var ceolMarks = {
  enabled: false,     // the app has asked for the highlighter on this page
  on: false,          // marking now
  tool: "y",          // a colour key, or "x" for the rubber
  byTune: [],         // [[{a, b, c}]] one list per tune shown
  pending: null,      // {t, n}: the first of two taps
  drag: null,         // {t, from, to, x, y, moved, id}
  drawTimer: 0,
  confirmClear: 0
};

var CEOL_MARK_COLOURS = {
  y: "#ffd92e",
  g: "#5fd67a",
  p: "#ff7eb0",
  b: "#62b8ff"
};
var CEOL_MARK_ORDER = ["y", "g", "p", "b"];
var CEOL_MARK_NAMES = { y: "Yellow", g: "Green", p: "Pink", b: "Blue" };

// MARK: Where the music is

/// The element each tune's music is drawn in, in order: the one tune of a tune
/// page, or each tune of a set.
function ceolMarkHosts() {
  var paper = document.getElementById("paper");
  if (paper) return [paper];
  var hosts = [];
  for (var i = 0; ; i++) {
    var el = document.getElementById("tune-vis-" + i);
    if (!el) break;
    hosts.push(el);
  }
  return hosts;
}

/// A tune's notes and rests, in the order they are played.
function ceolMarkNotes(host) {
  return Array.prototype.slice.call(host.querySelectorAll(".abcjs-note, .abcjs-rest"));
}

function ceolMarkPrinting() {
  return (typeof printMode !== "undefined" && printMode);
}

// MARK: The marks themselves

function ceolMarkClean(list) {
  var out = [];
  (list || []).forEach(function (m) {
    if (!m) return;
    var a = Math.floor(Number(m.a)), b = Math.floor(Number(m.b));
    if (!isFinite(a) || !isFinite(b) || !CEOL_MARK_COLOURS[m.c]) return;
    if (b < a) { var s = a; a = b; b = s; }
    if (b < 0) return;
    out.push({ a: Math.max(0, a), b: b, c: m.c });
  });
  out.sort(function (p, q) { return p.a - q.a; });
  // Two of a colour that touch are one mark.
  var merged = [];
  out.forEach(function (m) {
    var last = merged[merged.length - 1];
    if (last && last.c === m.c && m.a <= last.b + 1) last.b = Math.max(last.b, m.b);
    else merged.push(m);
  });
  return merged;
}

function ceolMarkParse(text) {
  if (!text) return [];
  try { return ceolMarkClean(JSON.parse(text)); } catch (e) { return []; }
}

function ceolMarkText(list) {
  return (list && list.length) ? JSON.stringify(list) : "";
}

/// Paint notes a…b of a tune in a colour, or (colour null) rub them out. What
/// was there before is cut back to make room, so there is one colour on any
/// note and the newest wins.
function ceolMarkPaint(t, a, b, colour) {
  if (b < a) { var s = a; a = b; b = s; }
  var next = [];
  (ceolMarks.byTune[t] || []).forEach(function (m) {
    if (m.b < a || m.a > b) { next.push(m); return; }
    if (m.a < a) next.push({ a: m.a, b: a - 1, c: m.c });
    if (m.b > b) next.push({ a: b + 1, b: m.b, c: m.c });
  });
  if (colour) next.push({ a: a, b: b, c: colour });
  ceolMarks.byTune[t] = ceolMarkClean(next);
}

/// The mark on a note, if there is one.
function ceolMarkAt(t, n) {
  var list = ceolMarks.byTune[t] || [];
  for (var i = 0; i < list.length; i++) {
    if (n >= list[i].a && n <= list[i].b) return list[i];
  }
  return null;
}

function ceolMarkSave(t) {
  try {
    window.webkit.messageHandlers.marks.postMessage({
      tune: t, marks: ceolMarkText(ceolMarks.byTune[t])
    });
  } catch (e) {}
}

/// From the app: each shown tune's marks, as the text it stores. Calling this
/// at all is what puts the highlighter button on the page.
function ceolSetMarks(texts) {
  ceolMarks.enabled = true;
  var changed = false;
  var count = Math.max((texts || []).length, ceolMarks.byTune.length);
  for (var i = 0; i < count; i++) {
    var incoming = ceolMarkParse((texts || [])[i]);
    if (ceolMarkText(incoming) !== ceolMarkText(ceolMarks.byTune[i] || [])) changed = true;
    ceolMarks.byTune[i] = incoming;
  }
  ceolMarks.byTune.length = (texts || []).length;
  ceolMarkToolbar();
  if (changed) { ceolMarks.pending = null; ceolMarkDraw(); }
}

// MARK: Drawing

function ceolMarkBox(el, inverse) {
  // The element's box on screen, taken into its SVG's own coordinates, so the
  // band is right however the SVG has been scaled.
  var r = el.getBoundingClientRect();
  var p1 = new DOMPoint(r.left, r.top).matrixTransform(inverse);
  var p2 = new DOMPoint(r.right, r.bottom).matrixTransform(inverse);
  return { x1: Math.min(p1.x, p2.x), y1: Math.min(p1.y, p2.y),
           x2: Math.max(p1.x, p2.x), y2: Math.max(p1.y, p2.y) };
}

/// The line of music a note is on. abcjs wraps each line in a group, whether
/// it draws the whole tune as one SVG or an SVG a line.
function ceolMarkLineOf(note) {
  return note.closest(".abcjs-staff-wrapper") || note.closest("svg");
}

/// One line of music: its SVG, the stave's box and each note's box in it.
function ceolMarkLines(host) {
  var notes = ceolMarkNotes(host);
  var lines = [], byLine = [];
  notes.forEach(function (note, index) {
    var svg = note.closest("svg");
    var wrapper = ceolMarkLineOf(note);
    if (!svg || !wrapper) return;
    var at = byLine.indexOf(wrapper);
    if (at < 0) {
      var ctm = svg.getScreenCTM();
      if (!ctm) return;
      var inverse = ctm.inverse();
      var stave = null;
      Array.prototype.forEach.call(wrapper.querySelectorAll(".abcjs-staff"), function (s) {
        var box = ceolMarkBox(s, inverse);
        if (box.x2 - box.x1 < 1) return;
        if (!stave) stave = box;
        else {
          stave.x1 = Math.min(stave.x1, box.x1); stave.y1 = Math.min(stave.y1, box.y1);
          stave.x2 = Math.max(stave.x2, box.x2); stave.y2 = Math.max(stave.y2, box.y2);
        }
      });
      byLine.push(wrapper);
      lines.push({ svg: svg, inverse: inverse, stave: stave, notes: [] });
      at = lines.length - 1;
    }
    lines[at].notes.push({ index: index, box: ceolMarkBox(note, lines[at].inverse) });
  });
  return lines;
}

function ceolMarkRect(svg, x1, y1, x2, y2, colour, dashed) {
  var rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
  rect.setAttribute("class", "ceol-mark");
  rect.setAttribute("x", x1.toFixed(2));
  rect.setAttribute("y", y1.toFixed(2));
  rect.setAttribute("width", Math.max(1, x2 - x1).toFixed(2));
  rect.setAttribute("height", Math.max(1, y2 - y1).toFixed(2));
  rect.setAttribute("rx", "4");
  rect.setAttribute("fill", colour);
  rect.setAttribute("fill-opacity", dashed ? "0.25" : "0.5");
  if (dashed) {
    rect.setAttribute("stroke", colour);
    rect.setAttribute("stroke-width", "1.5");
    rect.setAttribute("stroke-dasharray", "4 3");
  }
  rect.setAttribute("pointer-events", "none");
  // Behind the notes, as ink from a highlighter is.
  svg.insertBefore(rect, svg.firstChild);
}

/// Draw one run of notes on whichever lines it crosses.
function ceolMarkBand(lines, a, b, colour, dashed) {
  lines.forEach(function (line) {
    var first = null, last = null, top = Infinity, bottom = -Infinity;
    line.notes.forEach(function (n) {
      if (n.index < a || n.index > b) return;
      if (!first) first = n;
      last = n;
      top = Math.min(top, n.box.y1); bottom = Math.max(bottom, n.box.y2);
    });
    if (!first) return;
    var lineFirst = line.notes[0], lineLast = line.notes[line.notes.length - 1];
    var pad = 3;
    var x1 = first.box.x1 - pad, x2 = last.box.x2 + pad;
    if (line.stave) {
      top = Math.min(top, line.stave.y1); bottom = Math.max(bottom, line.stave.y2);
      // Carried over from the line above, or on to the line below: run to the
      // edge of the stave, so it reads as one stroke.
      if (a < lineFirst.index && first === lineFirst) x1 = Math.min(x1, lineFirst.box.x1 - 8);
      if (b > lineLast.index && last === lineLast) x2 = Math.max(x2, line.stave.x2);
    }
    ceolMarkRect(line.svg, x1, top - pad, x2, bottom + pad, colour, dashed);
  });
}

function ceolMarkDrawNow() {
  ceolMarks.drawTimer = 0;
  var hosts = ceolMarkHosts();
  hosts.forEach(function (host, t) {
    Array.prototype.forEach.call(host.querySelectorAll(".ceol-mark"), function (el) {
      if (el.parentNode) el.parentNode.removeChild(el);
    });
    if (ceolMarkPrinting()) return;
    var marks = ceolMarks.byTune[t] || [];
    var drag = (ceolMarks.drag && ceolMarks.drag.moved && ceolMarks.drag.t === t) ? ceolMarks.drag : null;
    var pending = (ceolMarks.pending && ceolMarks.pending.t === t) ? ceolMarks.pending : null;
    if (!marks.length && !drag && !pending) return;
    var lines = ceolMarkLines(host);
    marks.forEach(function (m) {
      ceolMarkBand(lines, m.a, m.b, CEOL_MARK_COLOURS[m.c], false);
    });
    if (drag) {
      var a = Math.min(drag.from, drag.to), b = Math.max(drag.from, drag.to);
      ceolMarkBand(lines, a, b, ceolMarks.tool === "x" ? "#8e8e93" : CEOL_MARK_COLOURS[ceolMarks.tool], true);
    }
    if (pending) {
      ceolMarkBand(lines, pending.n, pending.n,
                   ceolMarks.tool === "x" ? "#8e8e93" : CEOL_MARK_COLOURS[ceolMarks.tool], true);
    }
  });
}

/// Soon, and once however many times it's asked for.
function ceolMarkDraw() {
  if (ceolMarks.drawTimer) return;
  ceolMarks.drawTimer = setTimeout(ceolMarkDrawNow, 40);
}

// The music is redrawn from a dozen places (size, transpose, rotation, a new
// tune, the set's sections). Rather than have each of them remember the
// highlighter, watch for the drawing changing and put the marks back.
(function () {
  function watch() {
    var root = document.getElementById("paper") || document.getElementById("sections")
      || document.getElementById("scroller");
    if (!root || typeof MutationObserver === "undefined") return;
    new MutationObserver(function (records) {
      if (!ceolMarks.enabled) return;
      for (var i = 0; i < records.length; i++) {
        var nodes = Array.prototype.slice.call(records[i].addedNodes)
          .concat(Array.prototype.slice.call(records[i].removedNodes));
        for (var j = 0; j < nodes.length; j++) {
          var n = nodes[j];
          // Our own bands coming and going don't count, or this would never stop.
          if (n.nodeType === 1 && n.getAttribute && n.getAttribute("class") === "ceol-mark") continue;
          ceolMarkDraw();
          return;
        }
      }
    }).observe(root, { childList: true, subtree: true });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch);
  else watch();
})();

// MARK: Marking by hand

/// The note nearest a point on screen: on the line of music the point is over
/// (or nearest to), the note closest across.
function ceolMarkNoteAt(x, y) {
  var hosts = ceolMarkHosts();
  var best = null;
  hosts.forEach(function (host, t) {
    var hostBox = host.getBoundingClientRect();
    if (y < hostBox.top - 20 || y > hostBox.bottom + 20) return;
    var notes = ceolMarkNotes(host);
    var lineBoxes = [], lineEls = [];
    notes.forEach(function (note, n) {
      var lineEl = ceolMarkLineOf(note);
      if (!lineEl) return;
      var at = lineEls.indexOf(lineEl);
      if (at < 0) { lineEls.push(lineEl); lineBoxes.push(lineEl.getBoundingClientRect()); at = lineEls.length - 1; }
      var line = lineBoxes[at];
      // How far off this line the point is, up or down. Lines sit one under
      // another, so this picks the line; the distance across then picks the note.
      var off = y < line.top ? line.top - y : (y > line.bottom ? y - line.bottom : 0);
      var r = note.getBoundingClientRect();
      var across = x < r.left ? r.left - x : (x > r.right ? x - r.right : 0);
      var score = off * 1000 + across;
      if (!best || score < best.score) best = { t: t, n: n, score: score, off: off, across: across };
    });
  });
  if (!best || best.off > 40) return null;
  return best;
}

function ceolMarkInMusic(target) {
  if (!target || !target.closest) return false;
  if (target.closest("#ceolMarkBar")) return false;
  return !!(target.closest("#paper") || target.closest("[id^='tune-vis-']"));
}

function ceolMarkCommit(t, a, b) {
  if (ceolMarks.tool === "x") {
    if (a === b) {
      // A tap with the rubber takes the whole mark.
      var hit = ceolMarkAt(t, a);
      if (!hit) return;
      ceolMarkPaint(t, hit.a, hit.b, null);
    } else {
      ceolMarkPaint(t, a, b, null);
    }
  } else {
    ceolMarkPaint(t, a, b, ceolMarks.tool);
  }
  ceolMarkSave(t);
}

window.addEventListener("pointerdown", function (e) {
  if (!ceolMarks.on || !ceolMarkInMusic(e.target)) return;
  if (e.pointerType === "mouse" && e.button !== 0) return;
  e.stopPropagation();
  var note = ceolMarkNoteAt(e.clientX, e.clientY);
  if (!note) { ceolMarks.drag = null; return; }
  ceolMarks.drag = { t: note.t, from: note.n, to: note.n, x: e.clientX, y: e.clientY,
                     moved: false, id: e.pointerId };
}, true);

window.addEventListener("pointermove", function (e) {
  var d = ceolMarks.drag;
  if (!ceolMarks.on || !d || d.id !== e.pointerId) return;
  if (!d.moved && Math.abs(e.clientX - d.x) < 8 && Math.abs(e.clientY - d.y) < 8) return;
  var note = ceolMarkNoteAt(e.clientX, e.clientY);
  if (!note || note.t !== d.t) return;
  d.moved = true;
  ceolMarks.pending = null;
  if (note.n !== d.to) { d.to = note.n; ceolMarkDraw(); }
  else if (!ceolMarks.drawTimer) ceolMarkDraw();
}, true);

window.addEventListener("pointerup", function (e) {
  var d = ceolMarks.drag;
  if (!ceolMarks.on || !d || d.id !== e.pointerId) return;
  ceolMarks.drag = null;
  if (d.moved) {
    ceolMarkCommit(d.t, Math.min(d.from, d.to), Math.max(d.from, d.to));
  } else if (ceolMarks.tool === "x") {
    ceolMarkCommit(d.t, d.from, d.from);
  } else if (ceolMarks.pending && ceolMarks.pending.t === d.t) {
    // The second of two taps: everything between them.
    var first = ceolMarks.pending.n;
    ceolMarks.pending = null;
    ceolMarkCommit(d.t, Math.min(first, d.from), Math.max(first, d.from));
  } else {
    ceolMarks.pending = { t: d.t, n: d.from };
  }
  ceolMarkToolbar();
  ceolMarkDraw();
}, true);

// The page scrolled under the finger instead (a phone, dragging down): that
// was a scroll, not a mark.
window.addEventListener("pointercancel", function (e) {
  if (ceolMarks.drag && ceolMarks.drag.id === e.pointerId) {
    ceolMarks.drag = null;
    ceolMarkDraw();
  }
}, true);

// While the highlighter is on, the music's own taps (play from here, loop
// these bars, select a note) stand aside.
["click", "mousedown", "mouseup", "touchstart", "touchend"].forEach(function (name) {
  window.addEventListener(name, function (e) {
    if (!ceolMarks.on || !ceolMarkInMusic(e.target)) return;
    e.stopPropagation();
    if (name === "click") e.preventDefault();
  }, true);
});

// MARK: The buttons

function ceolMarkStyle() {
  if (document.getElementById("ceolMarkStyle")) return;
  var css = document.createElement("style");
  css.id = "ceolMarkStyle";
  css.textContent = [
    "#ceolMarkBar { position: fixed; right: 10px; bottom: 10px; z-index: 60;",
    "  display: flex; align-items: center; gap: 6px; padding: 5px;",
    "  border-radius: 22px; background: rgba(250,250,250,0.94);",
    "  box-shadow: 0 1px 6px rgba(0,0,0,0.25); -webkit-user-select: none; user-select: none;",
    "  font: 600 12px -apple-system, system-ui, sans-serif; color: #1c1c1e; }",
    "html.dark #ceolMarkBar { background: rgba(44,44,46,0.94); color: #f2f2f7; }",
    "#ceolMarkBar button { all: unset; box-sizing: border-box; cursor: pointer;",
    "  width: 32px; height: 32px; border-radius: 16px; display: flex;",
    "  align-items: center; justify-content: center; }",
    "#ceolMarkBar button.ceol-mark-wide { width: auto; padding: 0 10px; white-space: nowrap; }",
    "#ceolMarkBar .ceol-mark-dot { border: 2px solid transparent; }",
    "#ceolMarkBar .ceol-mark-dot.sel { border-color: currentColor; }",
    "#ceolMarkBar .ceol-mark-dot i { display: block; width: 20px; height: 20px; border-radius: 10px; }",
    "#ceolMarkBar .ceol-mark-tool.sel { background: rgba(120,120,128,0.3); }",
    "#ceolMarkBar .ceol-mark-main.on { background: #2f6b4f; color: #fff; }",
    "#ceolMarkBar svg { width: 20px; height: 20px; }",
    "#ceolMarkHint { position: fixed; right: 10px; bottom: 58px; z-index: 60; max-width: 240px;",
    "  padding: 6px 10px; border-radius: 10px; background: rgba(28,28,30,0.86); color: #fff;",
    "  font: 500 12px -apple-system, system-ui, sans-serif; }",
    // On while marking: a drag along the stave is a mark, a drag down the page
    // still scrolls it.
    "html.ceol-marking #paper, html.ceol-marking [id^='tune-vis-'] { touch-action: pan-y; cursor: crosshair; }",
    "@media print { #ceolMarkBar, #ceolMarkHint, .ceol-mark { display: none !important; } }"
  ].join("\n");
  document.head.appendChild(css);
}

var CEOL_MARK_ICONS = {
  pen: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14.5 4.5l5 5L10 19H5v-5z"/><path d="M12 7l5 5"/><path d="M3 21.5h18" stroke-width="2.4"/></svg>',
  rubber: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8.5 19L3.5 14a1.5 1.5 0 010-2.1l8.4-8.4a1.5 1.5 0 012.1 0l6.5 6.5a1.5 1.5 0 010 2.1L13.6 19z"/><path d="M8 8.5l7.5 7.5"/><path d="M8.5 19H21"/></svg>',
  bin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16"/><path d="M9 7V4.5h6V7"/><path d="M6.5 7l1 13h9l1-13"/></svg>'
};

function ceolMarkButton(cls, label, html, action) {
  var b = document.createElement("button");
  b.className = cls;
  b.setAttribute("aria-label", label);
  b.title = label;
  b.innerHTML = html;
  b.addEventListener("click", function (e) { e.stopPropagation(); e.preventDefault(); action(); });
  return b;
}

function ceolMarkAny() {
  for (var i = 0; i < ceolMarks.byTune.length; i++) {
    if ((ceolMarks.byTune[i] || []).length) return true;
  }
  return false;
}

/// Build (or rebuild) the buttons to match the state.
function ceolMarkToolbar() {
  if (!ceolMarks.enabled || ceolMarkPrinting()) return;
  ceolMarkStyle();
  var bar = document.getElementById("ceolMarkBar");
  if (!bar) {
    bar = document.createElement("div");
    bar.id = "ceolMarkBar";
    document.body.appendChild(bar);
  }
  bar.innerHTML = "";
  document.documentElement.classList.toggle("ceol-marking", ceolMarks.on);

  if (ceolMarks.on) {
    CEOL_MARK_ORDER.forEach(function (key) {
      bar.appendChild(ceolMarkButton(
        "ceol-mark-dot" + (ceolMarks.tool === key ? " sel" : ""), CEOL_MARK_NAMES[key],
        '<i style="background:' + CEOL_MARK_COLOURS[key] + '"></i>',
        function () { ceolMarks.tool = key; ceolMarks.confirmClear = 0; ceolMarkToolbar(); ceolMarkDraw(); }));
    });
    bar.appendChild(ceolMarkButton(
      "ceol-mark-tool" + (ceolMarks.tool === "x" ? " sel" : ""), "Rub out", CEOL_MARK_ICONS.rubber,
      function () {
        ceolMarks.tool = "x"; ceolMarks.pending = null; ceolMarks.confirmClear = 0;
        ceolMarkToolbar(); ceolMarkDraw();
      }));
    if (ceolMarkAny()) {
      if (ceolMarks.confirmClear) {
        bar.appendChild(ceolMarkButton("ceol-mark-wide", "Clear every mark", "Clear all?", function () {
          ceolMarks.confirmClear = 0;
          for (var t = 0; t < ceolMarks.byTune.length; t++) {
            if ((ceolMarks.byTune[t] || []).length) { ceolMarks.byTune[t] = []; ceolMarkSave(t); }
          }
          ceolMarks.pending = null;
          ceolMarkToolbar(); ceolMarkDraw();
        }));
      } else {
        bar.appendChild(ceolMarkButton("ceol-mark-tool", "Clear every mark", CEOL_MARK_ICONS.bin, function () {
          ceolMarks.confirmClear = 1;
          ceolMarkToolbar();
        }));
      }
    }
  }
  bar.appendChild(ceolMarkButton(
    "ceol-mark-main" + (ceolMarks.on ? " on" : ""),
    ceolMarks.on ? "Finish highlighting" : "Highlighter", CEOL_MARK_ICONS.pen,
    function () {
      ceolMarks.on = !ceolMarks.on;
      ceolMarks.pending = null; ceolMarks.drag = null; ceolMarks.confirmClear = 0;
      ceolMarkToolbar(); ceolMarkDraw();
    }));

  // One line of help, only while it's needed.
  var hint = document.getElementById("ceolMarkHint");
  var text = "";
  if (ceolMarks.on) {
    if (ceolMarks.tool === "x") text = "Tap a mark to remove it, or drag over part of one.";
    else if (ceolMarks.pending) text = "Now tap the last note.";
    else if (!ceolMarkAny()) text = "Drag along the notes, or tap the first note and then the last.";
  }
  if (text) {
    if (!hint) {
      hint = document.createElement("div");
      hint.id = "ceolMarkHint";
      document.body.appendChild(hint);
    }
    hint.textContent = text;
  } else if (hint && hint.parentNode) {
    hint.parentNode.removeChild(hint);
  }
}
