# Recording an instrument for Fonn

Fonn can use a real player's sound for the fiddle or the accordion. Record the
instrument on its own, then `make_instrument.py` cuts the recording into one
sound per note.

## What to record

**One instrument, nobody else.** No backing, no second player, no tapping
feet. A tune recorded at a session won't work: the other instruments are in
every note.

**Somewhere dry.** A living room with curtains and a sofa is better than a
kitchen or a hall. Any echo in the room ends up in every note Fonn plays.

**Close.** The phone or microphone about an arm's length away. Fiddle: in
front of the f-holes, a little above. Accordion: in front of the treble side.

**Not too loud.** If the recording app shows a level, keep the loudest notes
well below the top. A clipped note is thrown away.

## What to play (about 10 minutes all told)

1. **Long notes, up the instrument.** Every note from the bottom to the top,
   chromatically if possible, each held for about two seconds with a short
   gap between. Play them evenly at a comfortable session volume: no swells,
   and not much vibrato (a little is fine). This is the part that matters most.
   - Fiddle: open G (G3) up to about E6 is plenty.
   - Accordion: the whole treble range you'd use for tunes.
2. **The same again, a little quieter.** This is optional, but useful.
3. **A couple of tunes, played plainly.** Fewer rolls and cuts than usual.
   These fill in notes the long notes missed, and catch the instrument as it
   really speaks in a tune.

Save the recordings as WAV or M4A, at the best quality the app offers. MP3 is
all right if that's all there is.

## Turning it into sounds

    python3 make_instrument.py violin long-notes.wav quieter.wav tune1.wav --out fiddle/
    python3 make_instrument.py accordion box-notes.wav box-tune.wav --out accordion/

It prints which notes it found. It also lists any it had to retune a long way
from a neighbour, which are worth recording.
`report.json` says where each note came from.

## Permission

Only use recordings the player is happy to have in Fonn. Fonn is on the
App Store, so the sounds go out to everyone who installs it. A line from them
saying so is enough. Credit them in Acknowledgements if they'd like.
