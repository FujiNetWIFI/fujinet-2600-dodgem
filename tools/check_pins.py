#!/usr/bin/env python3
"""check_pins.py -- a label in the pinned span means the same thing everywhere.

The pinned span exists because a table reached through a ZERO-PAGE POINTER is
addressed from a bank that may not be the one that built the pointer. So every
label in that span must resolve to the SAME address in every bank that defines
it, and this reads the assembler's own symbol tables and says so.

It is a gate because the failure is silent and slow. LFE6C came out as $1794 in
three banks and $15A3 in the fourth -- a code address, because that bank's
region began nine bytes inside the DB that holds the table and the
nearest-preceding-label search could not see the real one. Everything
assembled. The build ran. 291 frames later a car crashed, the crash animation
loaded $A7 with a pointer into the middle of the dot engine, and the picture
filled with garbage.

`make det` can find that, but only by running for long enough to reach the
event, and only if the event happens at all. This finds it in the symbol table
before the image is linked.

ONLY THE PINNED SPAN IS CHECKED, and that restriction is the point rather than
a weakening. A code label SHOULD differ between banks -- the regions are packed
independently and cross-bank control flow goes through DMGOTO, never through a
raw address -- and so should a table read absolutely, which the assembler
resolves inside the bank that reads it. What cannot differ is anything whose
address travels through RAM.

Usage: check_pins.py <lo> <hi> <listing.lst> [listing.lst ...]
"""
import re
import sys

SYM = re.compile(r'\b(L[0-9A-F]{4})\s*:\s*([0-9A-F]{4})')


def symbols(path):
    out = {}
    for ln in open(path, errors='replace'):
        for name, addr in SYM.findall(ln):
            out.setdefault(name, int(addr, 16))
    return out


def main():
    lo, hi = int(sys.argv[1], 0), int(sys.argv[2], 0)
    lsts = sys.argv[3:]
    seen = {}
    for p in lsts:
        for name, addr in symbols(p).items():
            stock = int(name[1:], 16)
            if not lo <= stock <= hi:
                continue
            seen.setdefault(name, {})[p] = addr

    bad, checked = [], 0
    for name, where in sorted(seen.items()):
        if len(where) < 2:
            continue
        checked += 1
        vals = set(where.values())
        if len(vals) > 1:
            bad.append("%s resolves to %s" % (name, ", ".join(
                "$%04X in %s" % (a, p.split("/")[-1])
                for p, a in sorted(where.items()))))

    print("check_pins: %d pinned-span labels defined in more than one bank "
          "($%04X-$%04X)" % (checked, lo, hi))
    if bad:
        for b in bad:
            print("  " + b)
        sys.exit("check_pins: FAIL -- %d label(s) disagree across banks. A "
                 "pointer built in one bank and followed in another will miss."
                 % len(bad))
    print("check_pins: PASS -- every shared label is at one address everywhere")


if __name__ == '__main__':
    main()
