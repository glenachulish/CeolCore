// node tools/verify_edittools.js — checks Web/edittools.js against real abcjs.
const path = require("path");
global.ABCJS = require(path.join(__dirname, "../Sources/CeolCore/Web/abcjs-basic-min.js"));
const T = require(path.join(__dirname, "../Sources/CeolCore/Web/edittools.js"));
let fails = 0;
function eq(name, got, want) {
  if (got === want) console.log("ok   " + name);
  else { fails++; console.log("FAIL " + name + "\n  got:  " + JSON.stringify(got) + "\n  want: " + JSON.stringify(want)); }
}
function body(abc) { return abc.slice(abc.indexOf("\nK:") + 1).split("\n").slice(1).join("\n").trim(); }

const reel = "X:1\nT:Test Reel\nR:reel\nM:4/4\nL:1/8\nK:D\n\"D\"FAAB A2FA|dfed B2AF|\n";
const jig  = "X:1\nT:Test Jig\nR:jig\nM:6/8\nL:1/8\nK:G\nD|G3 GAB|AGE E2D|\n";

// Reading
const t = T.ceolReadTune(reel);
eq("reel bars", t.bars.length, 2);
eq("reel notes", t.notes.length, 14);
eq("A2 at beat 2", t.notes[4].beat, 2);
eq("chord read", t.notes[0].chordRanges[0][2], "D");
const tj = T.ceolReadTune(jig);
eq("pickup D on last beat", tj.notes[0].beat, 1);
eq("pickup flagged", tj.bars[0].pickup, true);

// Swing
eq("lilt", body(T.ceolSwing(reel, "lilt").abc), "\"D\"F>AA>B A2F>A|d>fe>d B2A>F|");
eq("straighten back", body(T.ceolSwing(T.ceolSwing(reel, "lilt").abc, "straight").abc), "\"D\"FAAB A2FA|dfed B2AF|");
eq("snap 2,4", body(T.ceolSwing(reel, "snap", [1, 3]).abc), "\"D\"F>AA<B A2F<A|d>fe<d B2A<F|");
eq("jig not swung", T.ceolSwing(jig, "lilt").changed, 0);

// Ornaments
eq("sligo jig: roll + cran-free", body(T.ceolOrnament(jig, "irish-flowing", 3).abc), "D|G{A}G{F}G GAB|AGE {F}E2D|");
const jigD = "X:1\nT:x\nM:6/8\nL:1/8\nK:D\nD3 FAd|A3 A2F|\n";
eq("cran on low D", body(T.ceolOrnament(jigD, "irish-flowing", 3).abc), "{A}D{G}D{F}D FAd|A{B}A{G}A A2F|");
eq("reel short roll + cut", body(T.ceolOrnament(reel, "irish-flowing", 3).abc), "\"D\"FA{B}AB {B}A{G}AFA|dfed {c}B{A}BAF|");
eq("donegal treble", body(T.ceolOrnament(reel, "donegal", 3).abc), "\"D\"FA{B}AB (3AAAFA|dfed (3BBBAF|");
eq("pipes", body(T.ceolOrnament(reel, "pipes", 3).abc), "\"D\"FA{gAd}AB {gAd}A2FA|{gde}df{gef}ed {gBd}B2{gAd}AF|");
eq("density 1: only bar starts", body(T.ceolOrnament(jig, "irish-flowing", 1).abc), "D|G{A}G{F}G GAB|AGE E2D|");
eq("strip", body(T.ceolStripOrnaments(T.ceolOrnament(reel, "pipes", 3).abc).abc), "\"D\"FAAB A2FA|dfed B2AF|");
const strath = "X:1\nT:s\nR:strathspey\nM:4/4\nL:1/8\nK:A\nA>Bc>d e2c>A|\n";
eq("speyside strathspey snaps", body(T.ceolOrnament(strath, "speyside", 2).abc), "{B}A>Bc<d {f}e2c<A|");

// The regional styles
eq("old names still work", body(T.ceolOrnament(jig, "irish-flowing", 3).abc), body(T.ceolOrnament(jig, "sligo", 3).abc));
eq("leitrim: beat cuts", body(T.ceolOrnament(reel, "leitrim", 3).abc), "\"D\"{G}FA{B}AB A2{G}FA|{e}df{f}ed B2{B}AF|");
eq("kerry: slides from below", body(T.ceolOrnament(reel, "kerry", 2).abc), "\"D\"FA{B}AB {G}A2FA|dfed {A}B2AF|");
eq("shetland: triplet turns", body(T.ceolOrnament(reel, "shetland", 3).abc), "\"D\"FA{B}AB (3ABAFA|dfed (3BcBAF|");
eq("west highland: G grace notes", body(T.ceolOrnament(reel, "westcoast", 2).abc), "\"D\"FA{g}AB {g}A2FA|dfed {g}B2AF|");
eq("every style named", T.CEOL_ORNAMENT_STYLES.map(s => s.id).join(","), "sligo,leitrim,clare,kerry,donegal,speyside,westcoast,shetland,pipes");

// Chords
const keyChords = T.ceolKeyChords(t).map(c => c.name).join(" ");
eq("D major chords", keyChords, "D Em F#m G A A7 Bm");
const tmix = T.ceolReadTune("X:1\nT:m\nM:4/4\nL:1/8\nK:Amix\nABcd|\n");
eq("A mix chords", T.ceolKeyChords(tmix).map(c => c.name).join(" "), "A Bm D Em F#m G");
const slots = T.ceolChordSlots(t);
eq("slots", slots.length, 4);
eq("slot 0 chord", slots[0].chords.join(), "D");
let edited = T.ceolSetSlotChord(reel, t, slots[1], "G");
eq("set slot 1", body(edited), "\"D\"FAAB \"G\"A2FA|dfed B2AF|");
edited = T.ceolSetSlotChord(edited, T.ceolReadTune(edited), T.ceolChordSlots(T.ceolReadTune(edited))[0], "Bm");
eq("replace slot 0", body(edited), "\"Bm\"FAAB \"G\"A2FA|dfed B2AF|");
edited = T.ceolSetSlotChord(edited, T.ceolReadTune(edited), T.ceolChordSlots(T.ceolReadTune(edited))[0], "");
eq("clear slot 0", body(edited), "FAAB \"G\"A2FA|dfed B2AF|");
eq("annotation kept", body(T.ceolClearChords("X:1\nM:4/4\nL:1/8\nK:D\n\"^fine\"\"D\"AB|\n")), "\"^fine\"AB|");
eq("shift +2", body(T.ceolShiftChords("X:1\nM:4/4\nL:1/8\nK:D\n\"D\"AB \"A7\"cd \"D/F#\"e|\n", 2)), "\"E\"AB \"B7\"cd \"E/G#\"e|");

// Compose
const tpl = T.ceolComposeTemplate({ type: "jig", key: "G", title: "My Jig" });
eq("template renders", T.ceolReadTune(tpl).bars.length, 16);
let at = tpl.indexOf("|: ") + 3, cur = { abc: tpl, cursor: at };
["G", "A", "B"].forEach(n => { cur = T.ceolComposeInsert(cur.abc, cur.cursor, n, 1); });
cur = T.ceolComposeInsert(cur.abc, cur.cursor, "c3", 3);
eq("bar 1 filled", cur.abc.split("\n")[9].slice(0, 16), "|: GABc3 | x6 | ");
eq("cursor moved to next bar", cur.abc.slice(cur.cursor, cur.cursor + 2), "x6");
cur = T.ceolComposeInsert(cur.abc, cur.cursor, "d2", 2);
const fin = T.ceolComposeFinal(cur.abc);
eq("final", body(fin), "P:A\n|: GABc3 | d2z4 :|");
eq("final renders", T.ceolReadTune(fin).bars.length, 2);
eq("empty final", T.ceolComposeFinal(tpl), "");

// Semiquavers and deleting
let c2 = { abc: T.ceolComposeTemplate({ type: "reel" }), cursor: 0 };
c2.cursor = c2.abc.indexOf("|: ") + 3;
c2 = T.ceolComposeInsert(c2.abc, c2.cursor, "A/", 0.5);
eq("half-unit filler", c2.abc.slice(c2.cursor, c2.cursor + 4), "x15/");
const noteEnd = c2.cursor;
c2 = T.ceolComposeInsert(c2.abc, c2.cursor, "B/", 0.5);
c2 = T.ceolComposeDelete(c2.abc, noteEnd, noteEnd + 2, 0.5);
eq("delete gives the length back", c2.abc.split("\n")[9].slice(0, 11), "|: A/x15/ |");
eq("final with semiquaver", body(T.ceolComposeFinal(c2.abc)), "P:A\n|: A/z15/ :|");

// Layout (FONN-LAYOUT-1)
const head = "X:1\nT:Test\nM:4/4\nL:1/8\nK:D\n";
const oneBar = head + "|:FAAB A2FA|\ndfed B2AF|\nFAAB A2FA|\ndfed e2d2:|\n|:fafd d2fd|\nedef g2fg|\nfafd d2fd|\nedef d4:|\n";
eq("short lines found", T.ceolLayoutProblems(oneBar).map(p => p.id).join(), "short");
eq("tidy joins each part", body(T.ceolTidyLayout(oneBar)), "|:FAAB A2FA|dfed B2AF|FAAB A2FA|dfed e2d2:|\n|:fafd d2fd|edef g2fg|fafd d2fd|edef d4:|");
const messy = head + "|:FAAB A2FA|!dfed B2\u200bAF|\r\n\r\nFAAB\u00a0A2FA|dfed e2d2:|\n";
eq("messy found", T.ceolLayoutProblems(messy).map(p => p.id).join(), "blank,bang,hidden");
eq("messy tidied", body(T.ceolTidyLayout(messy)), "|:FAAB A2FA| dfed B2AF|FAAB A2FA|dfed e2d2:|");
eq("tidy keeps decorations", body(T.ceolTidyLayout(head + "!trill!A2 B2|\nc4|\n")), "!trill!A2 B2|c4|");
eq("tidy keeps P: and w:", body(T.ceolTidyLayout(head + "P:A\nAB|\ncd|]\nP:B\nef|\nw:la la\n")), "P:A\nAB|cd|]\nP:B\nef|\nw:la la");
eq("clean tune: nothing", T.ceolLayoutProblems(head + "|:FAAB A2FA|dfed B2AF|FAAB A2FA|dfed e2d2:|\n").length, 0);
eq("no bar lines", T.ceolLayoutProblems(head + "FAABA2FAdfedB2AFFAABA2FAdfede2d2fafd\n").map(p => p.id).join(), "nobars");

// Endings and pickups in a composed tune
const withEnds = "X:1\nT:E\nR:reel\nM:4/4\nL:1/8\nK:D\nP:A\nD|: G4A4 | x8 |1 d4G4 :|2 x8 |]\nP:B\n|: x8 | x8 :|\n";
eq("empty 2nd ending: plain repeat", body(T.ceolComposeFinal(withEnds)), "P:A\nD|: G4A4 | d4G4 :|");
eq("filled 2nd ending kept", body(T.ceolComposeFinal(withEnds.replace("2 x8", "2 B4A4"))), "P:A\nD|: G4A4 |1 d4G4 :|2 B4A4 |]");

// Snippets (FONN-SNIPPETS-1)
eq("snippet: first two bars", body(T.ceolIncipit(reel)), "\"D\"FAAB A2FA|dfed B2AF |]");
eq("snippet keeps the pickup", body(T.ceolIncipit(jig)), "D|G3 GAB|AGE E2D |]");
eq("snippet drops the title", /T:/.test(T.ceolIncipit(reel)), false);
eq("snippet of a long tune is two bars", T.ceolReadTune(T.ceolIncipit(oneBar)).bars.length, 2);

eq("tempo: crotchets", T.ceolTempoQpm("Q:1/4=100\n"), 100);
eq("tempo: dotted crotchets", T.ceolTempoQpm("Q:3/8=110\n"), 165);
eq("tempo: bare number", T.ceolTempoQpm("Q:120\n"), 120);
eq("snippet has no tempo line", /Q:/.test(T.ceolIncipit("X:1\nT:x\nQ:1/4=90\nM:4/4\nL:1/8\nK:D\nABcd efga|bagf edcB|AAAA|\n")), false);

console.log(fails ? fails + " FAILED" : "all passed");
process.exit(fails ? 1 : 0);
