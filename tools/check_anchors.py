#!/usr/bin/env python3
"""check_anchors.py -- every declared patch site is where patches.py says.

The patch map anchors on an ADDRESS plus the bytes that must be at it. This
proves the second half against the actual dump, before anything builds on the
map. Three ways a declaration can be wrong and all three are checked:

  * the bytes at the address are not the declared ones -- the map has rotted,
    or somebody transcribed an address by hand;
  * the address is not an instruction boundary at all, so the "bytes" are the
    tail of one instruction and the head of the next, and a patch there would
    corrupt both;
  * two declarations name the same address.

It also reports the line of rom/dodgem.asm each site falls on, so an error
message can say where to look even though nothing here anchors on line numbers.

Usage: check_anchors.py rom/dodgem.bin build/dm_org.lst rom/dodgem.asm
"""
import re
import sys

import patches
import zpmap


def line_index(path, rom, base, code):
    """address -> (line number, text) of the generated disassembly."""
    lab = re.compile(r'^(L?F[0-9A-F]{3}):')
    out, addr = {}, None
    for i, ln in enumerate(open(path).read().splitlines(), 1):
        m = lab.match(ln)
        if m:
            addr = int(m.group(1).lstrip('L'), 16)
        if addr is None:
            continue
        rest = ln[m.end():] if m else ln
        b = rest.split()
        if not b or b[0].startswith(';') or b[0] in ('.byte', '.word', 'ORG',
                                                     'processor'):
            continue
        if addr in code:
            out[addr] = (i, ln.rstrip())
            addr += zpmap.LEN[rom[addr - base]] or 1
    return out


def main():
    rom = open(sys.argv[1], 'rb').read()
    base = 0x10000 - len(rom)
    code = zpmap.code_addresses(sys.argv[2])
    lines = line_index(sys.argv[3], rom, base, code)

    bad, seen, n = [], {}, 0
    for section, entries in patches.ALL:
        for addr, want, new, why in entries:
            n += 1
            if addr in seen:
                bad.append("$%04X declared twice: %s and %s"
                           % (addr, seen[addr], section))
            seen[addr] = section
            if addr not in code:
                bad.append("$%04X (%s: %s) is not an instruction boundary"
                           % (addr, section, why))
                continue
            wb = bytes(int(x, 16) for x in want.split())
            got = rom[addr - base:addr - base + len(wb)]
            if got != wb:
                i = lines.get(addr, (0, '?'))
                bad.append("$%04X (%s: %s) should be %s, the dump has %s "
                           "-- line %d: %s"
                           % (addr, section, why, want,
                              " ".join("%02X" % b for b in got),
                              i[0], i[1].strip()))

    # The one immediate that LOOKS like a pointer high byte and is not. If it
    # ever moves into POINTERS the port will relocate the dot-bitmap seed as
    # though it were an address, so the exclusion is asserted rather than
    # left as a comment.
    for addr, want, why in patches.NOT_A_POINTER:
        if addr in seen:
            bad.append("$%04X is declared in %s but it %s"
                       % (addr, seen[addr], why))
        wb = bytes(int(x, 16) for x in want.split())
        if rom[addr - base:addr - base + len(wb)] != wb:
            bad.append("$%04X: the not-a-pointer exclusion no longer matches "
                       "the dump" % addr)

    print("check_anchors: %d declared sites, %d distinct addresses" % (n, len(seen)))
    if bad:
        for b in bad:
            print("  " + b)
        sys.exit("check_anchors: FAIL -- %d problems" % len(bad))
    print("check_anchors: PASS -- every site is an instruction boundary "
          "carrying the declared bytes")


if __name__ == '__main__':
    main()
