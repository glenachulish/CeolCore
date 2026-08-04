# ABC harness

Render Ceòl's ABC through **the app's own copy of abcjs**, headlessly, and
count what actually came out.

```sh
npm install
node render.js cases/*.abc
node render.js --diff cases/transition-key-change-BEFORE.abc cases/transition-key-change.abc
```

## Why

Reading ABC and reasoning about it is not the same as engraving it. Several
confident theories about this app's notation turned out to be wrong, and the
only thing that settled them was rendering the real notation and counting what
appeared. Three failures in particular look completely fine in the source:

- **A missing key change.** A tune engraved under the previous tune's key
  signature has its accidentals quietly rewritten. Where the two keys happen to
  share a signature — D major and A mixolydian, say — nothing looks wrong at
  all.
- **A blank line.** A blank line ends a tune in ABC. Anything after it becomes a
  separate piece and simply does not appear. No error is reported.
- **A stranded repeat.** abcjs's line wrapping can leave a repeat sign at the
  end of a line where it means nothing. See `ceolCureStrandedRepeat` in
  `abc.html` for the measured fix and what didn't work.

`render.js` reports staves, key and time signatures, annotations, accidentals,
notes, bars, and any warnings abcjs raised — plus an explicit check for a blank
line in the body, because that one is silent.

Use `--diff` before and after changing anything about engraving. A change that
reports "nothing — the render is identical" did not do what you thought.

## Which abcjs

The app's copy, never one from npm — the point is to test what ships. It looks
for `abcjs-basic-min.js` in `Sources/CeolCore/Resources/` first, then in the iOS
app's `Resources/`, which is where it lives until the resources move. Override
with `CEOL_ABCJS`.

## Cases

`cases/transition-key-change.abc` is a real pair from the library, The Leitrim
Fancy into Langstrom's Pony — D major into A mixolydian. The `-BEFORE` file is
what `SetABCBuilder.transitionABC` used to produce: no marker at the join, and
one key signature applied to both tunes.

```
before  2 staves, 2 keysigs, 0 annotations
after   2 staves, 3 keysigs, 2 annotations
```

The third key signature is the change being engraved at the join. That is the
whole of the fix, and it is the sort of thing worth having a number for.
