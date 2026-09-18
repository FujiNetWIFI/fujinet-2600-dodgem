#!/usr/bin/env python3
"""dmphase.py -- what each frame phase actually touches, and therefore the banks.

THE SPLIT IS BY PHASE, NOT BY ADDRESS, and that distinction is the whole
reason this tool exists.

The tempting measurement is the one that asks where in the address space the
code divides most cleanly -- which boundary the fewest branches cross, since a
relative branch cannot be trampolined. Dodge 'Em answers that question very
well: there are boundaries at $F5A0 and $FC48 that no branch crosses at all,
against ten at the naive midpoint.

It is the wrong question. A bank switch is a JUMP: everything that executes
between two switches has to be in one bank, including every subroutine the
code calls and every table it reads. Minimising branches across an address
boundary says nothing about that, and a split chosen that way needs a switch at
every cross-bank JSR -- eighteen a frame here, where the sibling ports do two.

So the measurement is the TRANSITIVE FOOTPRINT of each frame phase: the
instructions reachable from its entry with calls followed, plus the data it
reads. Two phases may share a subroutine, and then it is carried in both banks;
that is Dragster's lesson (its PORTING.md 4) that a bank is a SET of regions
and not an interval.

Usage: dmphase.py [rom/dodgem.bin build/dm_org.lst]
"""
import sys

import zpmap                    # the decode tables, the walk, the index bounds

DATA_LO, DATA_HI = 0xFD62, 0xFFFF

# Absolute loads and compares -- the instructions that READ a table. Stores are
# excluded (nothing in this game writes its own ROM) and so are JSR/JMP, whose
# operand is control flow and is accounted for by the walk itself.
ABS_READ = {0x0D, 0x19, 0x1D, 0x2C, 0x2D, 0x39, 0x3D, 0x4D, 0x59, 0x5D,
            0x6D, 0x79, 0x7D, 0xAC, 0xAD, 0xAE, 0xB9, 0xBC, 0xBD, 0xBE,
            0xCC, 0xCD, 0xD9, 0xDD, 0xEC, 0xED, 0xF9, 0xFD}
ABS_X = {0x1D, 0x3D, 0x5D, 0x7D, 0xBC, 0xBD, 0xDD, 0xFD, 0x1E, 0x3E, 0x5E,
         0x7E, 0xDE, 0xFE}
ABS_Y = {0x19, 0x39, 0x59, 0x79, 0xB9, 0xBE, 0xD9, 0xF9}


# Tables reached only through a zero-page pointer -- `lda ($A7),y`. The
# pointer is built from immediates (`lda #$6C / sta $A7 / lda #$FE / sta $A8`),
# so no absolute operand names them and a scan for operands alone would put
# the car and digit bitmaps in no bank at all.
POINTER_TARGETS = (0xFE64, 0xFE6C, 0xFE94)

# $F000-$F002 is `JMP LF0CA`, executed only from the reset vector. In the
# banked image the vector lives in the fixed tail and points at the cold stub
# there, so these three bytes belong to no bank -- and $1000-$1002 of each bank
# is exactly where that bank's entry trampoline goes instead.
RESET_STUB = range(0xF000, 0xF003)

# The proposed banks. VBL does not fit a 2K bank on its own, so it is cut at
# its one natural fissure -- $F228's `JSR LF859`, the whole dot-and-scoring
# engine, which nothing else calls. COLD rides with OVER because they overlap
# heavily and neither is near a bank.
BANKS = [
    ("G0  vblank, less the dot engine", 0xF0E4, {0xF859}),
    ("G1  the dot engine ($F859)",      0xF859, set()),
    ("G2  the display kernel",          0xF244, set()),
    ("G3  overscan",                    0xF420, set()),
    ("G3+ cold (rides with G3)",        0xF0CA, set()),
]


def table_extents(rom, base, code):
    """Split the data region into tables, and let a read claim the WHOLE one.

    Per-site index bounds are the wrong abstraction for a bank map. A bank
    either carries a table or it does not; which entries one frame happens to
    read is irrelevant, because the next frame reads different ones. So the
    region is cut at every address anything refers to, and each table runs to
    the next cut -- self-maintaining, where a hand-written extent list would
    drift the first time a table moved.
    """
    cuts = set(POINTER_TARGETS)
    for a in sorted(code):
        op = rom[a - base]
        if (LEN_OF(op)) != 3 or op not in ABS_READ:
            continue
        operand = rom[a - base + 1] | (rom[a - base + 2] << 8)
        if DATA_LO <= operand <= DATA_HI:
            cuts.add(operand)
    cuts.add(DATA_LO)
    edges = sorted(cuts) + [DATA_HI + 1]
    return [(edges[i], edges[i + 1] - 1) for i in range(len(edges) - 1)]


def LEN_OF(op):
    return zpmap.LEN[op] or 1


def table_of(extents, addr):
    for lo, hi in extents:
        if lo <= addr <= hi:
            return (lo, hi)
    return None


def footprint(rom, base, code, entry, extents=None, extra=()):
    """(instructions, code bytes, data bytes) reachable from one phase entry."""
    insns = zpmap.walk(rom, base, code, entry, zpmap.BOUNDS | set(extra))
    cbytes, data = set(), set()
    for a in insns:
        op = rom[a - base]
        n = zpmap.LEN[op] or 1
        cbytes.update(range(a, a + n))
        if n != 3 or op not in ABS_READ:
            continue
        operand = rom[a - base + 1] | (rom[a - base + 2] << 8)
        if not DATA_LO <= operand <= DATA_HI:
            continue
        t = table_of(extents, operand)
        if t is not None:
            data.update(range(t[0], t[1] + 1))

    # The pointer-reached tables, claimed by the phase that SEEDS the pointer.
    for a in insns:
        if rom[a - base] == 0xA9 and rom[a - base + 1] in (0xFD, 0xFE, 0xFF) \
                and a + 2 in insns and rom[a - base + 2] == 0x85:
            for lo in POINTER_TARGETS:
                if (lo >> 8) == rom[a - base + 1]:
                    t = table_of(extents, lo)
                    if t is not None:
                        data.update(range(t[0], t[1] + 1))
    return insns, cbytes, data


def regions(addrs):
    """A set of addresses as a list of contiguous [lo, hi] runs."""
    out = []
    for a in sorted(addrs):
        if out and a == out[-1][1] + 1:
            out[-1][1] = a
        else:
            out.append([a, a])
    return [tuple(r) for r in out]


def emit_map(rom, base, code, extents, path):
    """Write the computed region -> bank map for dmbanks.py.

    COMPUTED, not declared. Dragster's PORTING.md 4 says to work out the
    cross-bank reference set before writing any code; with four phases sharing
    subroutines and thirty tables that is thirty-odd regions, and a hand-written
    list of thirty regions is a list that rots on the first recut. dmbanks.py
    consumes this; nothing hand-edits it.
    """
    merged = {}
    for name, entry, extra in BANKS:
        key = name.split()[0].rstrip("+")
        _, cb, da = footprint(rom, base, code, entry, extents, extra)
        if key in merged:
            merged[key] = (merged[key][0] | cb, merged[key][1] | da)
        else:
            merged[key] = (cb, da)

    with open(path, "w") as f:
        f.write("# generated by dmphase.py -- do not edit\n")
        f.write("# bank -> the contiguous stock-address runs it must carry.\n")
        f.write("# A bank that is not mapped cannot be read, so a region two\n")
        f.write("# phases share appears in both.\n")
        f.write("BANK_REGIONS = {\n")
        for key in sorted(merged):
            cb, da = merged[key]
            f.write("    %r: [\n" % key)
            for lo, hi in regions(cb | da):
                f.write("        (0x%04X, 0x%04X),\n" % (lo, hi))
            f.write("    ],\n")
        f.write("}\n")
    return merged


def main():
    rom_path = sys.argv[1] if len(sys.argv) > 1 else 'rom/dodgem.bin'
    listing = sys.argv[2] if len(sys.argv) > 2 else 'build/dm_org.lst'
    rom = open(rom_path, 'rb').read()
    base = 0x10000 - len(rom)
    code = zpmap.code_addresses(listing)

    extents = table_extents(rom, base, code)
    fp = {}
    for name, entry in zpmap.PHASES:
        fp[name] = footprint(rom, base, code, entry, extents)
    print("%d tables in $%04X-$%04X, cut at every address anything refers to"
          % (len(extents), DATA_LO, DATA_HI))
    print()

    print("phase  entry   instrs   code   data   total   of 2048")
    print("-----  -----   ------   ----   ----   -----   -------")
    for name, entry in zpmap.PHASES:
        insns, cb, da = fp[name]
        tot = len(cb) + len(da)
        print("%-5s  $%04X   %6d   %4d   %4d   %5d   %s"
              % (name, entry, len(insns), len(cb), len(da), tot,
                 "fits" if tot <= 2048 else "OVER by %d" % (tot - 2048)))

    print()
    print("pairwise overlap, in bytes of code+data carried by BOTH:")
    names = [n for n, _ in zpmap.PHASES]
    print("        " + "".join("%7s" % n for n in names))
    for a in names:
        row = "%-7s" % a
        for b in names:
            ia = fp[a][1] | fp[a][2]
            ib = fp[b][1] | fp[b][2]
            row += "%7d" % (len(ia & ib) if a != b else len(ia))
        print(row)

    print()
    print("A zero here is a seam that costs nothing to bank across; a large")
    print("number is a region that has to be carried in both banks.")

    allb = set()
    for n in names:
        allb |= fp[n][1] | fp[n][2]
        
    lo = 0x10000 - len(rom)
    missed = sorted(a for a in range(lo, 0x10000)
                    if a not in allb and a < DATA_LO and a not in RESET_STUB)
    if missed:
        print()
        print("%d code bytes reached by NO phase -- the phase entry list is "
              "incomplete:" % len(missed))
        print("   " + " ".join("$%04X" % a for a in missed[:24])
              + (" ..." if len(missed) > 24 else ""))
        return 1
    print()
    print("every code byte is reached by at least one phase.")
    print()

    print("PROPOSED BANKS -- the same measurement, cut where the game divides")
    print("bank                                code   data   total   of 2048")
    print("----                                ----   ----   -----   -------")
    bf, total = {}, 0
    for name, entry, extra in BANKS:
        _, cb, da = footprint(rom, base, code, entry, extents, extra)
        bf[name] = (cb, da)
    merged = {}
    for name, entry, extra in BANKS:
        key = name.split()[0].rstrip("+")
        cb, da = bf[name]
        if key in merged:
            merged[key] = (merged[key][0] | cb, merged[key][1] | da,
                           merged[key][2])
        else:
            merged[key] = (cb, da, name)
    for key in sorted(merged):
        cb, da, name = merged[key]
        tot = len(cb) + len(da)
        total += tot
        print("%-35s %5d  %5d   %5d   %s"
              % (name, len(cb), len(da), tot,
                 "%d spare" % (2048 - tot) if tot <= 2048
                 else "OVER by %d" % (tot - 2048)))
    print()
    print("%d bytes carried across %d game banks, against %d in the "
          "cartridge." % (total, len(merged), (len(rom))))
    print("The excess over %d is duplication: a bank that is not mapped "
          "cannot be read," % len(rom))
    print("so a table two phases share is carried by both.")

    out = "build/dmregions.py"
    emit_map(rom, base, code, extents, out)
    nreg = sum(len(regions(cb | da)) for cb, da in
               [(merged[k][0], merged[k][1]) for k in merged])
    print()
    print("wrote %s: %d regions across %d banks" % (out, nreg, len(merged)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
