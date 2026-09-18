#!/usr/bin/env python3
"""ramdiff.py -- compare two per-frame state checksum streams.

`make det` proves two builds agree. It does NOT prove either of them does
anything -- two runs that both sit still are identical by definition, and the
Intellivision family lost a day to exactly that (PORTING.md §7.31: a draft that
dropped the call to the game's primary logic routine passed 256/256). So this
also requires the stream to CHANGE: a run whose checksum never moves is a
failure however well it matches.

`--from N` starts the comparison at frame N and `--align N` allows the two
streams to be offset by up to N frames. Both exist for one reason, and it is
specific enough to be worth stating rather than hiding in a flag.

The shim samples the console ONCE per frame, at $F051, and the game reads the
shadows on its next pass -- $F17C, then $F1F9, $F203 and $F376 in the logic,
then $F02B in the display setup. Stock reads the ports live at each of those.
So every input in the build is exactly ONE FRAME older than stock's, uniformly.

That placement is forced. $F051 is the spin that ends the one timed band this
console has, and a band is the only safe home for work whose length varies:
the shim does a hundred and fifty cycles more on one frame in four, and
anywhere outside the band those cycles become scanlines. Video Olympics 3.13 is
the account of paying that price the other way round.

A uniform one-frame input delay is invisible while nothing changes and becomes
a permanent OFFSET the moment something does -- RESET restarts the game, so the
build restarts one frame after stock and every state that follows is stock's,
one frame later. That is not a difference in what the simulation computes. It
is a difference in which frame the button landed on.

It is not a lockstep concern at all: both consoles in a match run this build
and sample at the same point, so they see the same edge on the same tick. What
it affects is only the comparison against a 1981 cartridge nobody is playing
against.

So the gate does the honest thing rather than the easy one. It finds the offset,
NAMES it, requires every remaining frame to be identical, AND requires the
game's own frame counter -- carried in its own column, not folded into the
checksum -- to differ by exactly that offset on every single frame. A build that
was genuinely one frame behind satisfies both. A build that had drifted would
fail the second even while passing the first.

Usage: ramdiff.py a.txt b.txt [--min-frames N] [--from N] [--align N]
"""

import sys


def load(path):
    """frame -> (checksum, the game's own 16-bit frame counter). The counter
    column is optional so that an older capture still loads."""
    out = {}
    for line in open(path):
        parts = line.split()
        if len(parts) >= 2 and parts[0].isdigit():
            try:
                cnt = int(parts[2], 16) if len(parts) > 2 else None
                out[int(parts[0])] = (int(parts[1], 16), cnt)
            except ValueError:
                pass
    return out


def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    minf = 200
    if "--min-frames" in sys.argv:
        minf = int(sys.argv[sys.argv.index("--min-frames") + 1])
    start = 0
    if "--from" in sys.argv:
        start = int(sys.argv[sys.argv.index("--from") + 1])
    align = 0
    if "--align" in sys.argv:
        align = int(sys.argv[sys.argv.index("--align") + 1])

    # Find the offset, if one is allowed. The best offset is the one that
    # matches the most frames; requiring it to match ALL of them is the
    # assertion below, not this search.
    off, best = 0, -1
    for d in range(-align, align + 1):
        shared = [f for f in a if f >= start and (f + d) in b]
        if len(shared) < minf:
            continue
        hits = sum(1 for f in shared if a[f][0] == b[f + d][0])
        if hits > best:
            off, best = d, hits
    b = {f - off: v for f, v in b.items()}
    common = sorted(f for f in (set(a) & set(b)) if f >= start)
    if len(common) < minf:
        print("ramdiff: only %d frames in common, wanted %d" % (len(common), minf),
              file=sys.stderr)
        return 1

    distinct = len({a[f][0] for f in common})
    if distinct < 2:
        print("ramdiff: the state never changed across %d frames -- the run "
              "proved nothing" % len(common), file=sys.stderr)
        return 1

    for f in common:
        if a[f][0] == b[f][0]:
            continue
        print("ramdiff: DIVERGED at frame %d: %04X vs %04X"
              % (f, a[f][0], b[f][0]), file=sys.stderr)
        near = [g for g in common if abs(g - f) <= 3]
        for g in near:
            print("   frame %5d  %04X  %04X%s"
                  % (g, a[g][0], b[g][0], "  <--" if a[g][0] != b[g][0] else ""),
                  file=sys.stderr)
        return 1

    # The frame counter, which is the one cell an offset legitimately moves.
    # It must move by EXACTLY the offset, on every frame, and by nothing else.
    bad = [f for f in common
           if a[f][1] is not None and b[f][1] is not None
           and ((b[f][1] - a[f][1]) & 0xFFFF) != (off & 0xFFFF)]
    if bad:
        f = bad[0]
        print("ramdiff: the frame counter moved by more than the offset at "
              "frame %d: stock $%04X, build $%04X, offset %d (%d frames)"
              % (f, a[f][1], b[f][1], off, len(bad)), file=sys.stderr)
        return 1

    note = " from frame %d" % start if start else ""
    if off:
        note += (", the build running %d frame(s) behind stock -- the shim's "
                 "uniform one-frame input delay" % off)
    print("ramdiff: %d frames identical%s, %d distinct states -- PASS"
          % (len(common), note, distinct))
    return 0


if __name__ == "__main__":
    sys.exit(main())
