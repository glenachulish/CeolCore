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
// FONN-MARKS-2: writing and drawing. The same toolbar has a pen and a text
// tool. A line you draw, or a few words you type, is pinned to the note it
// was made beside and measured in stave-heights from it, so it too moves with
// the music and keeps its size against the notes. They are kept in the same
// list as the highlights (so in the same place in the tune's record): a text
// is {k:"t", n, x, y, s, c}, a drawn line {k:"i", n, c, p:[x, y, x, y, …]},
// with x and y in hundredths of the stave's height from that note.
//
// Keeping them. Every change is handed to the app (the "marks" channel), which
// stores it on the tune; the app hands the marks back through ceolSetMarks
// whenever it shows a tune. Nothing is kept in the page.

var ceolMarks = {
  enabled: false,     // the app has asked for the highlighter on this page
  on: false,          // marking now
  tool: "h",          // "h" highlighter, "d" pen, "t" text, "x" rubber
  colour: "y",        // a colour key
  byTune: [],         // [[{a, b, c}]] the highlights, one list per tune shown
  extra: [],          // [[{k, n, …}]] the texts and drawn lines, likewise
  drawn: [],          // [{el, t, i}] what is on the page now, for tapping
  stroke: null,       // a line being drawn
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
// The pen and the text use stronger versions: a pale yellow line is no use.
var CEOL_INK_COLOURS = {
  y: "#e08a00",
  g: "#1e9e4a",
  p: "#e0245e",
  b: "#1a73e8"
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

/// The texts and drawn lines out of a stored list, tidied.
function ceolMarkCleanExtra(list) {
  var out = [];
  (list || []).forEach(function (m) {
    if (!m || !CEOL_MARK_COLOURS[m.c]) return;
    var n = Math.max(0, Math.floor(Number(m.n)));
    if (!isFinite(n)) return;
    if (m.k === "t") {
      var s = String(m.s || "").slice(0, 200);
      if (!s.trim()) return;
      out.push({ k: "t", n: n, x: Math.round(Number(m.x) || 0), y: Math.round(Number(m.y) || 0), s: s, c: m.c });
    } else if (m.k === "i" && m.p && m.p.length >= 4) {
      var pts = [];
      for (var i = 0; i + 1 < m.p.length && i < 4000; i += 2) {
        var x = Math.round(Number(m.p[i])), y = Math.round(Number(m.p[i + 1]));
        if (isFinite(x) && isFinite(y)) pts.push(x, y);
      }
      if (pts.length >= 4) out.push({ k: "i", n: n, c: m.c, p: pts });
    }
  });
  return out;
}

function ceolMarkParse(text) {
  if (!text) return { hi: [], ex: [] };
  try {
    var list = JSON.parse(text);
    return {
      hi: ceolMarkClean(list.filter(function (m) { return m && !m.k; })),
      ex: ceolMarkCleanExtra(list.filter(function (m) { return m && m.k; }))
    };
  } catch (e) { return { hi: [], ex: [] }; }
}

/// A tune's highlights, texts and drawn lines as the one text the app stores.
function ceolMarkText(hi, ex) {
  var all = (hi || []).concat(ex || []);
  return all.length ? JSON.stringify(all) : "";
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
      tune: t, marks: ceolMarkText(ceolMarks.byTune[t], ceolMarks.extra[t])
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
    if (ceolMarkText(incoming.hi, incoming.ex)
        !== ceolMarkText(ceolMarks.byTune[i] || [], ceolMarks.extra[i] || [])) changed = true;
    ceolMarks.byTune[i] = incoming.hi;
    ceolMarks.extra[i] = incoming.ex;
  }
  ceolMarks.byTune.length = (texts || []).length;
  ceolMarks.extra.length = (texts || []).length;
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

// MARK: Text and drawn lines

/// Where a note is, for pinning things to: the line it is on, the point they
/// are measured from (the note's middle, the top of the stave) and the unit
/// (a hundredth of the stave's height). A note that is no longer there — the
/// tune has been edited shorter — becomes the last one.
function ceolMarkAnchor(lines, n) {
  var found = null, lastLine = null, lastNote = null;
  lines.forEach(function (line) {
    line.notes.forEach(function (note) {
      if (note.index === n) found = { line: line, note: note };
      lastLine = line; lastNote = note;
    });
  });
  if (!found && lastNote) found = { line: lastLine, note: lastNote };
  if (!found) return null;
  var stave = found.line.stave
    || { y1: found.note.box.y1, y2: found.note.box.y1 + 31 };
  var height = Math.max(8, stave.y2 - stave.y1);
  return { line: found.line, x: (found.note.box.x1 + found.note.box.x2) / 2,
           y: stave.y1, unit: height / 100, height: height };
}

function ceolMarkPathData(anchor, pts) {
  var d = "";
  for (var i = 0; i + 1 < pts.length; i += 2) {
    d += (i ? " L " : "M ") + (anchor.x + pts[i] * anchor.unit).toFixed(1)
      + " " + (anchor.y + pts[i + 1] * anchor.unit).toFixed(1);
  }
  return d;
}

function ceolMarkInkEl(anchor, colour) {
  var path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("class", "ceol-mark");
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", colour);
  path.setAttribute("stroke-width", (anchor.height * 0.06).toFixed(2));
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  path.setAttribute("pointer-events", "none");
  return path;
}

/// Draw a tune's texts and lines, on top of the music.
function ceolMarkDrawExtras(lines, t) {
  (ceolMarks.extra[t] || []).forEach(function (m, i) {
    var anchor = ceolMarkAnchor(lines, m.n);
    if (!anchor) return;
    var el;
    if (m.k === "t") {
      el = document.createElementNS("http://www.w3.org/2000/svg", "text");
      el.setAttribute("class", "ceol-mark");
      el.setAttribute("x", (anchor.x + m.x * anchor.unit).toFixed(1));
      el.setAttribute("y", (anchor.y + m.y * anchor.unit).toFixed(1));
      el.setAttribute("font-size", (anchor.height * 0.5).toFixed(1));
      el.setAttribute("font-family", "-apple-system, system-ui, Helvetica, sans-serif");
      el.setAttribute("font-weight", "600");
      el.setAttribute("font-style", "normal");
      el.setAttribute("fill", CEOL_INK_COLOURS[m.c]);
      el.setAttribute("stroke", "none");
      el.setAttribute("pointer-events", "none");
      el.textContent = m.s;
    } else {
      el = ceolMarkInkEl(anchor, CEOL_INK_COLOURS[m.c]);
      el.setAttribute("d", ceolMarkPathData(anchor, m.p));
    }
    anchor.line.svg.appendChild(el);
    ceolMarks.drawn.push({ el: el, t: t, i: i });
  });
}

/// The text or drawn line at a point on screen, the smallest if several.
function ceolMarkExtraAt(x, y, textOnly) {
  var best = null;
  ceolMarks.drawn.forEach(function (d) {
    var item = (ceolMarks.extra[d.t] || [])[d.i];
    if (!item || (textOnly && item.k !== "t")) return;
    var r = d.el.getBoundingClientRect();
    var pad = 8;
    if (x < r.left - pad || x > r.right + pad || y < r.top - pad || y > r.bottom + pad) return;
    var area = (r.width + 1) * (r.height + 1);
    if (!best || area < best.area) best = { t: d.t, i: d.i, area: area };
  });
  return best;
}

/// A point on screen as a place pinned to the nearest note: which tune, which
/// note, and how far from it in hundredths of a stave.
function ceolMarkPin(x, y) {
  var near = ceolMarkNoteAt(x, y, true);
  if (!near) return null;
  var lines = ceolMarkLines(ceolMarkHosts()[near.t]);
  var anchor = ceolMarkAnchor(lines, near.n);
  if (!anchor) return null;
  var at = new DOMPoint(x, y).matrixTransform(anchor.line.inverse);
  return { t: near.t, n: near.n, anchor: anchor,
           x: Math.round((at.x - anchor.x) / anchor.unit),
           y: Math.round((at.y - anchor.y) / anchor.unit) };
}

function ceolMarkDrawNow() {
  ceolMarks.drawTimer = 0;
  ceolMarks.drawn = [];
  var hosts = ceolMarkHosts();
  hosts.forEach(function (host, t) {
    Array.prototype.forEach.call(host.querySelectorAll(".ceol-mark"), function (el) {
      if (el.parentNode) el.parentNode.removeChild(el);
    });
    if (ceolMarkPrinting()) return;
    var marks = ceolMarks.byTune[t] || [];
    var extras = ceolMarks.extra[t] || [];
    var drag = (ceolMarks.drag && ceolMarks.drag.moved && ceolMarks.drag.t === t) ? ceolMarks.drag : null;
    var pending = (ceolMarks.pending && ceolMarks.pending.t === t) ? ceolMarks.pending : null;
    if (!marks.length && !extras.length && !drag && !pending) return;
    var lines = ceolMarkLines(host);
    ceolMarkDrawExtras(lines, t);
    marks.forEach(function (m) {
      ceolMarkBand(lines, m.a, m.b, CEOL_MARK_COLOURS[m.c], false);
    });
    if (drag) {
      var a = Math.min(drag.from, drag.to), b = Math.max(drag.from, drag.to);
      ceolMarkBand(lines, a, b, ceolMarks.tool === "x" ? "#8e8e93" : CEOL_MARK_COLOURS[ceolMarks.colour], true);
    }
    if (pending) {
      ceolMarkBand(lines, pending.n, pending.n, CEOL_MARK_COLOURS[ceolMarks.colour], true);
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
function ceolMarkNoteAt(x, y, loose) {
  var hosts = ceolMarkHosts();
  var best = null;
  hosts.forEach(function (host, t) {
    var hostBox = host.getBoundingClientRect();
    var reach = loose ? 60 : 20;
    if (y < hostBox.top - reach || y > hostBox.bottom + reach) return;
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
  // The highlighter wants a note under the finger; a text or a drawn line can
  // sit well clear of the stave and still belongs to the nearest note.
  if (!best || (!loose && best.off > 40)) return null;
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
    ceolMarkPaint(t, a, b, ceolMarks.colour);
  }
  ceolMarkSave(t);
}

// MARK: Typing

/// A small box to type in, at a point on screen. `done` gets what was typed
/// (or null if it was abandoned). Not the browser's own prompt: the app's web
/// view has none.
function ceolMarkAskText(x, y, initial, done) {
  ceolMarkEndEntry(false);
  var box = document.createElement("div");
  box.id = "ceolMarkEntry";
  var left = Math.max(8, Math.min(x - 10, window.innerWidth - 228));
  var top = Math.max(8, Math.min(y - 20, window.innerHeight - 52));
  box.style.left = left + "px";
  box.style.top = top + "px";
  var input = document.createElement("input");
  input.type = "text";
  input.value = initial || "";
  input.maxLength = 200;
  input.setAttribute("autocapitalize", "sentences");
  input.setAttribute("autocomplete", "off");
  input.setAttribute("aria-label", "Text for the music");
  var ok = document.createElement("button");
  ok.textContent = "\u2713";
  ok.setAttribute("aria-label", "Done");
  box.appendChild(input);
  box.appendChild(ok);
  document.body.appendChild(box);
  var finished = false;
  function finish(keep) {
    if (finished) return;
    finished = true;
    ceolMarks.entry = null;
    var value = input.value;
    if (box.parentNode) box.parentNode.removeChild(box);
    done(keep ? value : null);
  }
  ceolMarks.entry = finish;
  input.addEventListener("keydown", function (e) {
    e.stopPropagation();
    if (e.key === "Enter") { e.preventDefault(); finish(true); }
    else if (e.key === "Escape") { e.preventDefault(); finish(false); }
  });
  ["keyup", "keypress"].forEach(function (name) {
    input.addEventListener(name, function (e) { e.stopPropagation(); });
  });
  input.addEventListener("blur", function () { setTimeout(function () { finish(true); }, 80); });
  ok.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); finish(true); });
  try { input.focus(); input.select(); } catch (e) {}
}

function ceolMarkEndEntry(keep) {
  if (ceolMarks.entry) ceolMarks.entry(keep);
}

/// A tap with the text tool: change the text that is there, or type a new one.
function ceolMarkTextTap(x, y) {
  var hit = ceolMarkExtraAt(x, y, true);
  if (hit) {
    var item = ceolMarks.extra[hit.t][hit.i];
    ceolMarkAskText(x, y, item.s, function (value) {
      if (value === null) return;
      var list = ceolMarks.extra[hit.t] || [];
      var at = list.indexOf(item);
      if (at < 0) return;
      if (value.trim()) item.s = value.slice(0, 200);
      else list.splice(at, 1);       // emptied: the text is taken away
      ceolMarkSave(hit.t); ceolMarkToolbar(); ceolMarkDraw();
    });
    return;
  }
  var pin = ceolMarkPin(x, y);
  if (!pin) return;
  var colour = ceolMarks.colour;
  ceolMarkAskText(x, y, "", function (value) {
    if (value === null || !value.trim()) return;
    if (!ceolMarks.extra[pin.t]) ceolMarks.extra[pin.t] = [];
    ceolMarks.extra[pin.t].push({ k: "t", n: pin.n, x: pin.x, y: pin.y,
                                  s: value.slice(0, 200), c: colour });
    ceolMarkSave(pin.t); ceolMarkToolbar(); ceolMarkDraw();
  });
}

// MARK: Drawing a line

function ceolMarkStrokeStart(e) {
  var pin = ceolMarkPin(e.clientX, e.clientY);
  if (!pin) return;
  var el = ceolMarkInkEl(pin.anchor, CEOL_INK_COLOURS[ceolMarks.colour]);
  pin.anchor.line.svg.appendChild(el);
  ceolMarks.stroke = { t: pin.t, n: pin.n, anchor: pin.anchor, el: el,
                       pts: [pin.x, pin.y], id: e.pointerId, c: ceolMarks.colour };
}

function ceolMarkStrokeMove(e) {
  var s = ceolMarks.stroke;
  var at = new DOMPoint(e.clientX, e.clientY).matrixTransform(s.anchor.line.inverse);
  var x = Math.round((at.x - s.anchor.x) / s.anchor.unit);
  var y = Math.round((at.y - s.anchor.y) / s.anchor.unit);
  var n = s.pts.length;
  // Not every twitch: a point only once the pen has moved a little.
  if (Math.abs(x - s.pts[n - 2]) + Math.abs(y - s.pts[n - 1]) < 4) return;
  if (n >= 4000) return;
  s.pts.push(x, y);
  s.el.setAttribute("d", ceolMarkPathData(s.anchor, s.pts));
}

function ceolMarkStrokeEnd(keep) {
  var s = ceolMarks.stroke;
  ceolMarks.stroke = null;
  if (!s) return;
  if (s.el.parentNode) s.el.parentNode.removeChild(s.el);
  if (keep && s.pts.length >= 4) {
    if (!ceolMarks.extra[s.t]) ceolMarks.extra[s.t] = [];
    ceolMarks.extra[s.t].push({ k: "i", n: s.n, c: s.c, p: s.pts });
    ceolMarkSave(s.t);
  }
  ceolMarkToolbar();
  ceolMarkDraw();
}

window.addEventListener("pointerdown", function (e) {
  if (!ceolMarks.on || !ceolMarkInMusic(e.target)) return;
  if (e.pointerType === "mouse" && e.button !== 0) return;
  e.stopPropagation();
  ceolMarkEndEntry(true);
  ceolMarks.drag = null;
  if (ceolMarks.tool === "d") { ceolMarkStrokeStart(e); return; }
  if (ceolMarks.tool === "t") { ceolMarks.tap = { x: e.clientX, y: e.clientY, id: e.pointerId }; return; }
  if (ceolMarks.tool === "x") {
    // The rubber on a text or a drawn line takes it away.
    var extra = ceolMarkExtraAt(e.clientX, e.clientY, false);
    if (extra) {
      ceolMarks.extra[extra.t].splice(extra.i, 1);
      ceolMarkSave(extra.t); ceolMarkToolbar(); ceolMarkDraw();
      return;
    }
  }
  var note = ceolMarkNoteAt(e.clientX, e.clientY);
  if (!note) { ceolMarks.drag = null; return; }
  ceolMarks.drag = { t: note.t, from: note.n, to: note.n, x: e.clientX, y: e.clientY,
                     moved: false, id: e.pointerId };
}, true);

window.addEventListener("pointermove", function (e) {
  if (ceolMarks.on && ceolMarks.stroke && ceolMarks.stroke.id === e.pointerId) {
    ceolMarkStrokeMove(e);
    return;
  }
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
  if (ceolMarks.stroke && ceolMarks.stroke.id === e.pointerId) {
    ceolMarkStrokeEnd(true);
    return;
  }
  var tap = ceolMarks.tap;
  if (tap && tap.id === e.pointerId) {
    ceolMarks.tap = null;
    // A tap, not the end of a scroll.
    if (ceolMarks.on && ceolMarks.tool === "t"
        && Math.abs(e.clientX - tap.x) < 10 && Math.abs(e.clientY - tap.y) < 10) {
      ceolMarkTextTap(e.clientX, e.clientY);
    }
    return;
  }
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
  if (ceolMarks.stroke && ceolMarks.stroke.id === e.pointerId) ceolMarkStrokeEnd(true);
  if (ceolMarks.tap && ceolMarks.tap.id === e.pointerId) ceolMarks.tap = null;
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
    "  display: flex; flex-wrap: wrap-reverse; justify-content: flex-end;",
    "  max-width: calc(100vw - 20px); box-sizing: border-box;",
    "  align-items: center; gap: 6px; padding: 5px;",
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
    // The pen needs every direction, so with it a finger draws and doesn't scroll.
    "html.ceol-marking-pen #paper, html.ceol-marking-pen [id^='tune-vis-'] { touch-action: none; }",
    "html.ceol-marking-text #paper, html.ceol-marking-text [id^='tune-vis-'] { cursor: text; }",
    "#ceolMarkEntry { position: fixed; z-index: 70; display: flex; gap: 4px; padding: 4px;",
    "  border-radius: 10px; background: rgba(250,250,250,0.97); box-shadow: 0 1px 8px rgba(0,0,0,0.35); }",
    "html.dark #ceolMarkEntry { background: rgba(44,44,46,0.97); }",
    "#ceolMarkEntry input { width: 170px; font: 16px -apple-system, system-ui, sans-serif;",
    "  border: 1px solid rgba(120,120,128,0.5); border-radius: 7px; padding: 5px 7px;",
    "  background: #fff; color: #1c1c1e; outline: none; }",
    "#ceolMarkEntry button { all: unset; cursor: pointer; width: 34px; text-align: center;",
    "  border-radius: 7px; background: #2f6b4f; color: #fff; font: 600 17px -apple-system, system-ui, sans-serif; }",
    "@media print { #ceolMarkBar, #ceolMarkHint, #ceolMarkEntry, .ceol-mark { display: none !important; } }"
  ].join("\n");
  document.head.appendChild(css);
}

var CEOL_MARK_ICONS = {
  pen: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14.5 4.5l5 5L10 19H5v-5z"/><path d="M12 7l5 5"/><path d="M3 21.5h18" stroke-width="2.4"/></svg>',
  marker: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 14l7.5-9.5 4 3L13 17z"/><path d="M9 14l-2 4.5 6-1.5"/><path d="M3 21h9" stroke-width="3.2"/></svg>',
  draw: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 17c2.5-6 4.5-6 6-2s3.5 4 5.5-1 3.5-5 6.5-1"/></svg>',
  text: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 7V5h14v2"/><path d="M12 5v14"/><path d="M9 19h6"/></svg>',
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
    if ((ceolMarks.byTune[i] || []).length || (ceolMarks.extra[i] || []).length) return true;
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
  var root = document.documentElement;
  root.classList.toggle("ceol-marking", ceolMarks.on);
  root.classList.toggle("ceol-marking-pen", ceolMarks.on && ceolMarks.tool === "d");
  root.classList.toggle("ceol-marking-text", ceolMarks.on && ceolMarks.tool === "t");

  if (ceolMarks.on) {
    // The colours show as the chosen tool will use them.
    var palette = (ceolMarks.tool === "d" || ceolMarks.tool === "t") ? CEOL_INK_COLOURS : CEOL_MARK_COLOURS;
    CEOL_MARK_ORDER.forEach(function (key) {
      bar.appendChild(ceolMarkButton(
        "ceol-mark-dot" + (ceolMarks.colour === key && ceolMarks.tool !== "x" ? " sel" : ""),
        CEOL_MARK_NAMES[key],
        '<i style="background:' + palette[key] + '"></i>',
        function () {
          ceolMarks.colour = key;
          if (ceolMarks.tool === "x") ceolMarks.tool = "h";
          ceolMarks.confirmClear = 0; ceolMarkToolbar(); ceolMarkDraw();
        }));
    });
    [["h", "Highlighter", CEOL_MARK_ICONS.marker],
     ["d", "Draw", CEOL_MARK_ICONS.draw],
     ["t", "Text", CEOL_MARK_ICONS.text],
     ["x", "Rub out", CEOL_MARK_ICONS.rubber]].forEach(function (tool) {
      bar.appendChild(ceolMarkButton(
        "ceol-mark-tool" + (ceolMarks.tool === tool[0] ? " sel" : ""), tool[1], tool[2],
        function () {
          ceolMarkEndEntry(true);
          ceolMarks.tool = tool[0]; ceolMarks.pending = null; ceolMarks.confirmClear = 0;
          ceolMarkToolbar(); ceolMarkDraw();
        }));
    });
    if (ceolMarkAny()) {
      if (ceolMarks.confirmClear) {
        bar.appendChild(ceolMarkButton("ceol-mark-wide", "Clear every mark", "Clear all?", function () {
          ceolMarks.confirmClear = 0;
          for (var t = 0; t < ceolMarks.byTune.length; t++) {
            if ((ceolMarks.byTune[t] || []).length || (ceolMarks.extra[t] || []).length) {
              ceolMarks.byTune[t] = []; ceolMarks.extra[t] = []; ceolMarkSave(t);
            }
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
    ceolMarks.on ? "Finish marking" : "Mark the music", CEOL_MARK_ICONS.pen,
    function () {
      ceolMarkEndEntry(true);
      ceolMarkStrokeEnd(false);
      ceolMarks.on = !ceolMarks.on;
      ceolMarks.pending = null; ceolMarks.drag = null; ceolMarks.confirmClear = 0;
      ceolMarkToolbar(); ceolMarkDraw();
    }));

  // One line of help, only while it's needed.
  var hint = document.getElementById("ceolMarkHint");
  var text = "";
  if (ceolMarks.on) {
    if (ceolMarks.tool === "x") text = "Tap a mark, a text or a drawn line to remove it, or drag over part of a highlight.";
    else if (ceolMarks.tool === "d") text = "Draw on the music. While the pen is chosen, a finger draws and doesn't scroll.";
    else if (ceolMarks.tool === "t") text = "Tap where the text should go. Tap a text to change it.";
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
