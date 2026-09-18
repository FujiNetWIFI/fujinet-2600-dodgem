#!/usr/bin/env python3
"""playdiff.py -- did the two consoles diverge, and did they come back?

Reads the two `S <n> <tick> <state>` streams emu/play.lua writes and reports
the ticks on which the simulations differ.

IT RECONSTRUCTS THE LAP, and that is the whole reason this is a tool rather
than a `diff`. The tick on the wire is EIGHT BITS. Keyed on it directly, tick
600 and tick 88 and tick 344 are the same key, every lap overwrites the last,
and a comparison that should have spanned nine hundred ticks silently spans the
final 256 -- which reported "0 differ" on a pair that had demonstrably
diverged. Combat's PORTING.md 4.19 says the relay has to do this too, and for
exactly the same reason.

Usage: playdiff.py c1.out c2.out
"""
import re
import sys

ROW = re.compile(r'^S (\d+) (\d+) ([0-9A-F]+)')


def load(path):
    out, lap, last = {}, 0, None
    for line in open(path, errors="replace"):
        m = ROW.match(line)
        if not m:
            continue
        t = int(m.group(2))
        # A tick that jumps backwards by more than half the range is a wrap,
        # not a reorder.
        if last is not None and t < last - 128:
            lap += 1
        last = t
        out[lap * 256 + t] = m.group(3)
    return out


def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    common = sorted(set(a) & set(b))
    if not common:
        sys.exit("playdiff: the two consoles share no ticks at all")
    diff = [t for t in common if a[t] != b[t]]

    print("playdiff: %d ticks compared (%d-%d), %d differ"
          % (len(common), common[0], common[-1], len(diff)))
    if not diff:
        print("playdiff: the two simulations never diverged")
        return 0

    after = [t for t in common if t > diff[-1]]
    # Name the first cell that went, because "they diverged" is not a
    # diagnosis. The state is a hex string of the cells DMCRC covers.
    t = diff[0]
    off = next(i for i, (x, y) in enumerate(zip(a[t], b[t])) if x != y) // 2
    print("playdiff: diverged at tick %d, cell %d of the compared set "
          "(%s vs %s)" % (t, off, a[t][off * 2:off * 2 + 2],
                          b[t][off * 2:off * 2 + 2]))
    print("playdiff: %d ticks of divergence, then %d ticks in agreement"
          % (len(diff), len(after)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
