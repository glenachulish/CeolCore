#!/usr/bin/env node
//
// Render ABC through the real abcjs, headlessly, and report what came out.
//
// Why this exists: several confident theories about engraving have turned out
// to be wrong, and the only thing that settled them was rendering the actual
// notation and counting what appeared. Reading the ABC and reasoning about it
// is not the same as engraving it — a missing key change, a stranded repeat or
// a tune silently truncated at a blank line all look fine in the source.
//
// This loads `abcjs-basic-min.js` — the same copy the app ships, not a version
// from npm — into jsdom, renders, and prints counts you can compare before and
// after a change.
//
//   node render.js cases/*.abc
//   node render.js --diff before.abc after.abc
//
// Setup:  npm install

const fs = require("fs");
const path = require("path");
const { JSDOM } = require("jsdom");

/// The app's own copy of abcjs. Checked in the package first, because that is
/// where the Resources folder lands once the move is finished, then in the iOS
/// app where it lives until then. CEOL_ABCJS overrides both.
function findABCJS() {
  const candidates = [
    process.env.CEOL_ABCJS,
    path.resolve(__dirname, "../../Sources/CeolCore/Resources/abcjs-basic-min.js"),
    path.resolve(__dirname, "../../../ios/Ceol/Resources/abcjs-basic-min.js"),
  ].filter(Boolean);
  const found = candidates.find((p) => fs.existsSync(p));
  if (!found) {
    console.error("Could not find abcjs-basic-min.js. Looked in:");
    candidates.forEach((c) => console.error("  " + c));
    console.error("Set CEOL_ABCJS to point at it.");
    process.exit(1);
  }
  return found;
}

const ABCJS_PATH = findABCJS();
const ABCJS_SRC = fs.readFileSync(ABCJS_PATH, "utf8");

/// One render in its own DOM. A fresh jsdom per tune, because abcjs keeps
/// state on the document and a shared one makes results depend on order.
function render(abc, options = {}) {
  const dom = new JSDOM(`<!DOCTYPE html><body><div id="paper"></div></body>`, {
    pretendToBeVisual: true,
  });
  new Function("window", "document", "navigator", ABCJS_SRC).call(
    dom.window, dom.window, dom.window.document, dom.window.navigator
  );
  const ABCJS = dom.window.ABCJS;
  if (!ABCJS) throw new Error("abcjs did not define ABCJS on window");

  const tunes = ABCJS.renderAbc("paper", abc, {
    add_classes: true,
    wrap: { minSpacing: 1.8, maxSpacing: 2.7, preferredMeasuresPerLine: 4 },
    ...options,
  });
  const svg = dom.window.document.getElementById("paper").innerHTML;
  const count = (re) => (svg.match(re) || []).length;

  return {
    tunes: tunes.length,
    staves: tunes[0] ? tunes[0].lines.filter((l) => l.staff).length : 0,
    keySignatures: count(/abcjs-key-signature/g),
    timeSignatures: count(/abcjs-time-signature/g),
    annotations: count(/abcjs-annotation/g),
    accidentals: count(/abcjs-accidental/g),
    notes: count(/abcjs-note\b/g),
    bars: count(/abcjs-bar\b/g),
    warnings: (tunes[0] && tunes[0].warnings) || null,
  };
}

/// A tune ends at a blank line in ABC. It is the single easiest way to lose
/// half a piece without any error being reported, so it is worth saying out
/// loud rather than leaving it to show up as a low note count.
function blankLineCheck(abc) {
  const body = abc.split(/\n(?=[^A-Za-z]|[A-Za-z][^:])/).slice(1).join("\n");
  return /\n\s*\n/.test(abc.replace(/^(?:[A-Za-z]:[^\n]*\n)+/, ""))
    ? "BLANK LINE IN BODY — everything after it is a separate tune"
    : null;
}

function report(label, abc) {
  const r = render(abc);
  const warn = blankLineCheck(abc);
  console.log(
    `${label.padEnd(28)} tunes=${r.tunes} staves=${r.staves} ` +
    `keysigs=${r.keySignatures} timesigs=${r.timeSignatures} ` +
    `annotations=${r.annotations} accidentals=${r.accidentals} ` +
    `notes=${r.notes} bars=${r.bars}`
  );
  if (r.warnings) console.log(`  abcjs warnings: ${JSON.stringify(r.warnings)}`);
  if (warn) console.log(`  ${warn}`);
  return r;
}

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error("usage: node render.js <file.abc> [more.abc ...]");
  console.error("       node render.js --diff before.abc after.abc");
  process.exit(1);
}

console.log(`abcjs: ${ABCJS_PATH}\n`);

if (args[0] === "--diff") {
  const [, before, after] = args;
  const b = report("before  " + path.basename(before), fs.readFileSync(before, "utf8"));
  const a = report("after   " + path.basename(after), fs.readFileSync(after, "utf8"));
  console.log("\nchanged:");
  let any = false;
  for (const k of Object.keys(b)) {
    if (k === "warnings") continue;
    if (b[k] !== a[k]) { console.log(`  ${k}: ${b[k]} -> ${a[k]}`); any = true; }
  }
  if (!any) console.log("  nothing — the render is identical");
} else {
  for (const f of args) report(path.basename(f), fs.readFileSync(f, "utf8"));
}
