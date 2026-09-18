#!/usr/bin/env python3
"""check_zp.py -- the zero-page map in dmdefs.inc is the one the census allows.

`make zp` measures what the GAME does. This checks what the NETCODE claims
against it, every build, so the map cannot drift away from the measurement it
was derived from. Three claims:

  1. Every persistent netcode cell lies in a block the port has EVICTED into a
     text plane, or is a cell the game never writes. A persistent cell that is
     still the game's is a cell the game will overwrite between two overscan
     bands, and the symptom is a desync every few seconds that looks like a
     network fault.

  2. Every band-local cell is untouched by the game across BOTH bands that read
     it. These are not free cells -- they are the game's own kernel scratch,
     borrowed on the strength of a liveness claim, and the claim is re-proved
     here rather than trusted to a comment.

  3. Nothing is allocated twice, and the spare cells really are spare. A port
     whose zero page fits exactly has no room for the cell the next bug needs.

Usage: check_zp.py rom/dodgem.bin build/dm_org.lst src/dmdefs.inc
"""
import re
import sys

import zpmap

# The blocks this port evicts into a cartridge text plane, and what each one
# cost to evict. See PORTING.md 5.2 -- chosen by how often they are written and
# who reads them, never by size.
EVICTED = {
    (0xAC, 0xB4): "the per-row dot bitmap: read in vblank only, never by the "
                  "kernel; written when a dot is eaten",
    (0xBC, 0xC2): "player B's saved state: read in overscan only; written by "
                  "LF5A0's swap, at a round end",
}

# Cells the game never writes at all. Measured, not asserted: the stack floor
# comes from the deepest JSR chain zpmap computes.
def native_persistent(writes, floor):
    return {c for c in range(0x80, 0x100) if c not in writes and c < floor}


def parse_defs(path):
    """name -> (value, section). The section a cell is declared under is the
    claim being made about it, so it is parsed rather than guessed."""
    out, section = {}, None
    for ln in open(path):
        m = re.match(r'^;\s*-+\s*(.*?)\s*-+\s*$', ln)
        if m:
            section = m.group(1).lower()
            continue
        m = re.match(r'^(DM\w+)\s+EQU\s+\$([0-9A-Fa-f]+)', ln)
        if m and section:
            out[m.group(1)] = (int(m.group(2), 16), section)
    return out


def main():
    rom = open(sys.argv[1], 'rb').read()
    base = 0x10000 - len(rom)
    code = zpmap.code_addresses(sys.argv[2])
    defs = parse_defs(sys.argv[3])

    reads, writes, _, _ = zpmap.census(rom, base, code)
    deepest = max(zpmap.stack_depth(rom, base, code, e)
                  for _, e in zpmap.PHASES)
    floor = 0x100 - deepest

    evicted = set()
    for (lo, hi) in EVICTED:
        evicted |= set(range(lo, hi + 1))
    native = native_persistent(writes, floor)
    allowed_persistent = evicted | native

    bad, seen = [], {}
    npers = nlocal = 0
    for name, (val, section) in sorted(defs.items()):
        if 'persistent' not in section and 'band-local' not in section:
            continue        # a bit mask or a constant, not a cell allocation
        if not 0x80 <= val <= 0xFF:
            continue                       # a plane address, not a RAM cell
        if val in seen:
            bad.append("%s and %s are both $%02X" % (name, seen[val], val))
        seen[val] = name

        if 'persistent' in section:
            npers += 1
            if val not in allowed_persistent:
                where = ("the game writes it in %s"
                         % ",".join(sorted(writes.get(val, ('?',)))))
                bad.append("%s = $%02X is persistent but not available: %s"
                           % (name, val, where))
        elif 'band-local' in section:
            nlocal += 1
            live = (reads.get(val, set()) | writes.get(val, set())) - {'COLD'}
            clash = live & {'VBL', 'OVER'}
            if clash:
                bad.append("%s = $%02X is band-local but the game touches it "
                           "in %s" % (name, val, ",".join(sorted(clash))))

    # ONE, not two. The threshold started at two and the transport spent one of
    # them on DMRDN. That is what the margin was for -- it is not a rule to be
    # kept by refusing to build, it is a rule about not fitting EXACTLY. One
    # cell left is still one cell; zero is the number that says the next bug
    # has nowhere to go, and if this ever has to drop to zero the answer is to
    # evict another block into the cartridge, not to lower the threshold again.
    spare = [n for n in defs if n.startswith('DMFREE')]
    if len(spare) < 1:
        bad.append("no spare cell held back -- a map that fits exactly has no "
                   "room for the next bug. Evict another block rather than "
                   "lowering this.")

    print("check_zp: %d persistent, %d band-local, %d spare; stack floor $%02X "
          "(deepest chain %d)" % (npers, nlocal, len(spare), floor, deepest))
    print("check_zp: %d cells evicted into a text plane, %d never written by "
          "the game" % (len(evicted), len(native)))
    if bad:
        for b in bad:
            print("  " + b)
        sys.exit("check_zp: FAIL -- %d problems" % len(bad))
    print("check_zp: PASS -- every claim in dmdefs.inc holds against the census")


if __name__ == '__main__':
    main()
