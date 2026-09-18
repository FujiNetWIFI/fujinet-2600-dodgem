#!/usr/bin/env python3
"""mkbanks.py -- split Tennis across the FujiNet cartridge's banks.

A FujiNet bank is the 2K at $1000-$17FF; the 2K above it is the cartridge's
mailbox and the client only owns the 220-byte tail inside it. Tennis is
exactly 2048 bytes, so it fills a bank precisely and leaves nowhere for netcode
-- which is why it is split: the display half and the network state machine in
one bank, the frame loop and the game logic in another.

THE REGIONS ARE DERIVED FROM THE ASSEMBLER'S OWN LISTING, never from line
numbers in this file. Every source line's address comes out of
build/tn_org.lst, which `make verify-org` has just proved reproduces the
cartridge dump byte for byte. A region boundary cannot drift away from the code
it is supposed to bound.

EVERY BYTE KEEPS THE ADDRESS IT HAS TODAY, rebased $F000 -> $1000. Each bank
simply leaves the other's regions empty, so every absolute JMP/JSR target and
every pointer low byte in the dispatch table stays byte-identical and
check_patch.py can be a real byte audit rather than a formality.

Usage: mkbanks.py <stock.lst> <tennis.asm> <out.inc>
"""

import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import dasm2as
import patches as patchmap

BASE = 0xF000           # where the disassembly puts Tennis
WINDOW = 0x1000         # where a FujiNet bank is mapped
REBASE = BASE - WINDOW

# (first, last+1, bank). Addresses are the STOCK ones; see the module docstring.
# `kind` matters to more than documentation: tools/checkrom.py walks every bank
# linearly looking for banned opcodes, and a linear walk through a data table is
# misaligned garbage. See tools/checkrom_filter.py.
REGIONS = [
    (0xF000, 0xF015, "GAME", "START -- rewritten: the bank entry dispatcher and "
                             "a JMP to the bounded clear", "code"),
    (0xF015, 0xF168, "KERN", "the per-frame display setup, the 192-line kernel "
                             "and the 24-line tail", "code"),
    (0xF168, 0xF497, "GAME", "VSYNC, the frame counters, RESET/SELECT, the whole "
                             "game logic, and JMP LF015", "code"),
    (0xF497, 0xF53B, "KERN", "LF497/LF4A1/LF4A3 sprite positioning, and the "
                             "LF4EE scoreboard kernel", "code"),
    (0xF53B, 0xF618, "GAME", "LF53B scoring and LF5E7 the new-point setup", "code"),
    (0xF618, 0xF649, "KERN", "LF618 -- the per-half sprite setup", "code"),
    (0xF649, 0xF700, "KERN", "the player and ball bitmaps, reached through "
                             "($A4),Y and its three siblings", "data"),
    (0xF700, 0xF72D, "BOTH", "THREE TABLES THAT BOTH BANKS READ, and the only "
                             "place the split is not clean. $F302 reads LF700 "
                             "and $F30B reads LF704, both in the game logic; "
                             "$F63A reads LF708,X with X in 0..1, which is "
                             "$F708 AND the first byte of LF709; and $F5E9 "
                             "copies LF709-LF72C into $90-$B3 as the new-point "
                             "init block. 45 bytes of read-only data in both "
                             "banks is cheaper than moving a boundary through "
                             "the middle of a table.", "data"),
    (0xF72D, 0xF75D, "KERN", "the two glyph-pointer tables and the colour and "
                             "black-and-white tables", "data"),
    (0xF75D, 0xF76D, "BOTH", "ONE 16-BYTE LINE THAT STRADDLES THE SPLIT. Its "
                             "first two bytes are the scoring tone, read by "
                             "$F549 in the game bank; the score font starts at "
                             "$F76A, ten bytes further in, and belongs to the "
                             "kernel. A region is filed by source LINE, so the "
                             "run goes to both banks whole.", "data"),
    (0xF76D, 0xF7FE, "KERN", "the rest of the score font, reached through "
                             "($AC),Y and its three siblings", "data"),
    (0xF7FE, 0xF800, "GAME", "THE DIFFICULTY-SWITCH MASKS, $40 and $80, read by "
                             "$F1FC as `AND LF7FE,X`. In a flat 2K cartridge "
                             "these two bytes are also the 6502 IRQ vector, and "
                             "David Crane reclaimed them as data -- there is no "
                             "BRK in the image and SEI runs at power-on, so the "
                             "vector is never taken. In the banked layout the "
                             "real vectors live in the fixed tail at $1FFC, so "
                             "these stay exactly what the game reads: data, in "
                             "the bank that reads them.", "data"),
]

# The three cross-bank references in the whole of Tennis, and they are why the
# EXPORT below is what it is. Two of them are reads of the tables now declared
# BOTH, so they cost nothing; the third is the seam.
#
#   $F494  JMP LF015     GAME -> KERN.  SEAM A.
#   $F302  LDA LF700,X   GAME -> the BOTH table
#   $F30B  LDA LF704,X   GAME -> the BOTH table
#
# THE TWO SEAMS COST NO PATCHED BYTES, for Dragster's reason: every byte keeps
# its cartridge address, so the bank that does not own a seam has a hole exactly
# there and the trampoline goes in the hole.
#
#   A: game -> display, at $F015. TWO ways in and one trampoline serves both --
#      `JMP LF015` at $F494 every frame, and the cold path falling out of
#      `JSR LF5E7` at $F012. Nothing is live across it: $F015 loads A and X
#      immediately and LF4A3 writes Y before reading it.
#
#   B: display -> game, at $F168, which is a FALL-THROUGH out of the 24-line
#      tail spin. The boundary is $F168 and not $F16C on purpose: `LDX #$03` at
#      $F168 feeds `STX WSYNC`/`STX VSYNC`/`STX VBLANK`, and TNGOTO clobbers X,
#      so putting the load on the game side means nothing has to survive the
#      switch. Y DOES survive, and must: the spin leaves Y = 0 and `$F17B DEY`
#      makes it $FF. TNGOTO never touches Y.
#
#      The switch costs about 35 cycles and they are FREE, because the next
#      instruction is `STX WSYNC`. The spin exits 7 cycles into a scanline, so
#      the store lands 42 cycles in and still waits out the same line. Stock
#      measures the same frame -- which `make frames` checks rather than
#      assumes.
EXPORT = {(0xF015, 0xF168)}


LST = re.compile(r"^\s*(\d+)/\s*([0-9A-F]{1,4}) :")
SYM = re.compile(r"^\s*\*?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([0-9A-F]{4})\s")
ORG = re.compile(r"^(\s*)ORG(\s+)\$F([0-9A-F]{3})\b", re.IGNORECASE)


def line_addresses(path):
    """line number -> the address the assembler put that line at."""
    addr = {}
    with open(path, errors="replace") as f:
        for line in f:
            m = LST.match(line)
            if m:
                addr.setdefault(int(m.group(1)), int(m.group(2), 16))
    return addr


def symbols(path):
    """label -> address, from the listing's symbol table."""
    out, in_tab = {}, False
    with open(path, errors="replace") as f:
        for line in f:
            if "Symbol Table" in line:
                in_tab = True
                continue
            if not in_tab:
                continue
            for part in line.split("|"):
                m = SYM.match(part)
                if m:
                    out[m.group(1)] = int(m.group(2), 16)
    return out



VCSINC = __file__.rsplit("/", 2)[0] + "/src/vcs.inc"


def _reconcile_equates(dropped, buckets):
    """DiStella writes its own equate block; every bank file includes vcs.inc;
    emitting both is a double definition. The equates are therefore dropped --
    but NOT the ones that would change the image if vcs.inc's value were used
    instead.

    DiStella names a register by the MIRROR the code actually used. The TIA
    decodes only A0-A3 for a read, so this ROM reaches its paddles through
    $38/$3A and its collision latches through $32/$36, and DiStella duly emits
    `CXP0FB = $32` where vcs.inc says `$02`. Both read the same register; they
    are DIFFERENT BYTES. Silently taking vcs.inc's value for a symbol the body
    references would change the cartridge and break the guarantee verify-org
    exists to give, somewhere much harder to read than here.

    So a referenced symbol whose value disagrees is KEPT, under a name that
    cannot collide, and the body is rewritten to use it. Returns the preamble
    lines to emit.
    """
    vcs = {}
    try:
        with open(VCSINC) as f:
            for line in f:
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s+EQU\s+(\S+)", line)
                if m:
                    vcs[m.group(1).upper()] = m.group(2)
    except OSError:
        return []

    def val(x):
        return int(x.lstrip("$"), 16)

    body = "".join("".join(b) for b in buckets)
    keep = []
    renames = {}
    for name, v in sorted(dropped.items()):
        if not re.search(r"\b%s\b" % re.escape(name), body, re.IGNORECASE):
            continue                    # emitted but never used: safe to drop
        theirs = vcs.get(name)
        if theirs is not None and val(theirs) == val(v):
            continue                    # same register, same byte: vcs.inc's will do
        new = name + "_M"
        renames[name] = new
        keep.append("%s\tEQU\t%s\t; the MIRROR the 1977 code used; vcs.inc says\n"
                    "\t\t\t\t;   %s -- the same register, a DIFFERENT byte\n"
                    % (new, v, theirs or "nothing"))
    if renames:
        pat = re.compile(r"\b(%s)\b" % "|".join(map(re.escape, renames)))
        for b in buckets:
            for i, line in enumerate(b):
                b[i] = pat.sub(lambda m: renames[m.group(1)], line)
    return keep


def region_of(addr):
    for i, (lo, hi, _bank, _why, _kind) in enumerate(REGIONS):
        if lo <= addr < hi:
            return i
    return None


def main():
    lst, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
    addr = line_addresses(lst)
    syms = symbols(lst)

    lines = patchmap.apply(open(src).readlines())

    # THE OPENING ORG IS FOUND, NOT COUNTED. Combat's version of this file
    # dropped "line 201", which was where its hand-written disassembly happened
    # to put the ORG that opens the image; the generator emits each region's
    # ORG itself, so keeping it would fight them. Carried over unchanged, that
    # constant silently deleted line 201 of THIS disassembly, which is an INX
    # in the SELECT handler -- one byte short, every byte after it displaced,
    # and a thousand undeclared differences pointing everywhere but here.
    #
    # A hardcoded line number that means something in one file means something
    # else in the next one. Match the directive instead.
    openorg = next((n for n, l in enumerate(lines, 1)
                    if re.match(r"^\s*ORG\s+\$F[0-9A-F]{3}\s*$", l.strip()
                                and l.rstrip() or "", re.IGNORECASE)), None)
    if openorg is None:
        raise SystemExit("mkbanks: no opening ORG found in " + src)

    # EVERY REGION BOUNDARY MUST FALL ON A SOURCE-LINE BOUNDARY. A region is
    # filed by the address of a line's FIRST byte, so a .byte run that spans a
    # boundary goes wholly into the region it starts in and the bytes past the
    # boundary never reach the other bank -- as filler, silently, 188 bytes of
    # it. Declare a straddling run as a BOTH region (see $F743 above) or move
    # the boundary; either way, decide it here rather than discover it in
    # check_patch.
    starts = set(addr.values())
    for lo, hi, bank, why, _kind in REGIONS:
        for edge in (lo, hi):
            if edge in (BASE, BASE + 0x800) or edge in starts:
                continue
            before = max((a for a in starts if a < edge), default=None)
            raise SystemExit(
                "mkbanks: region boundary $%04X is in the MIDDLE of the line "
                "that starts at $%04X.\n"
                "  The run there would be filed whole into one bank and the "
                "other would get filler.\n"
                "  Declare $%04X-$%04X as a BOTH region, or move the boundary "
                "to a line start." % (edge, before, before, edge))

    # Bucket every source line into the region its STOCK address falls in.
    # A comment line carries the address of the next byte to be emitted, so
    # header comments group with the code they introduce, which is what makes
    # the output readable rather than merely correct.
    buckets = [[] for _ in REGIONS]
    for n, raw in enumerate(lines, 1):
        a = addr.get(n)
        if a is None or a < BASE:
            continue                    # the equates and the header
        conv = dasm2as.convert(raw)
        # The body's own ORGs are rebased; the one at line 201 that opens the
        # image is dropped, because the generator emits a region's ORG itself.
        if n == openorg:
            continue
        conv = ORG.sub(lambda m: "%sORG%s$1%s" % (m.group(1), m.group(2), m.group(3)),
                       conv)
        r = region_of(a)
        if r is not None:
            buckets[r].append(conv)

    # The preamble: everything before the ORG.
    #
    # DiStella writes its OWN equate block for the TIA and RIOT registers, and
    # every bank file includes vcs.inc, so emitting them here is a double
    # definition of thirty-odd symbols. They are dropped -- but not on trust.
    #
    # The trap that makes the check worth its lines: DiStella names a register
    # by the MIRROR the code actually used. This ROM reads its paddles through
    # $38/$3A, so DiStella emits `INPT0 = $38` where vcs.inc says `INPT0 = $08`.
    # Both are the same register and both assemble to a working read, but they
    # are DIFFERENT BYTES, and silently taking vcs.inc's value for a symbol the
    # body referenced would change the image and break verify-org's guarantee
    # further downstream where it is much harder to read. Today the body uses
    # the literal address at those sites and the symbols are unreferenced; if a
    # future tools/vo.cfg ever makes one referenced, this fails the build.
    dropped = {}
    pre = []
    for n, raw in enumerate(lines, 1):
        if addr.get(n, 0) >= BASE or n == openorg:
            continue
        conv = dasm2as.convert(raw)
        if re.match(r"^\s*(CPU|INCLUDE)\b", conv, re.IGNORECASE):
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s+EQU\s+(\S+)", conv)
        if m:
            dropped[m.group(1).upper()] = m.group(2)
            continue
        pre.append(conv)
    pre += _reconcile_equates(dropped, buckets)

    with open(out, "w") as f:
        f.write("; generated by tools/mkbanks.py -- do not edit.\n"
                "; Tennis, split across the FujiNet cartridge's banks. Every byte keeps\n"
                "; the address it has in the cartridge dump, rebased $F000 -> $1000.\n"
                "; Selected by TNBANK; see tools/mkbanks.py for why the regions are what\n"
                "; they are, and tools/patches.py for every change made to the original.\n\n")
        f.writelines(pre)

        for i, (lo, hi, bank, why, _kind) in enumerate(REGIONS):
            end = hi
            f.write("\n; ---------------------------------------------------------------\n")
            f.write("; $%04X-$%04X  %s bank: %s\n"
                    % (lo - REBASE, end - 1 - REBASE, bank.lower(), why))
            if bank != "BOTH":
                f.write("        IF      TNBANK = BANK%s\n" % bank)
            f.write("        ORG     $%04X\n" % (lo - REBASE))
            f.writelines(buckets[i])
            # A label at the region's end, so the bank file can ORG into the
            # hole that follows without a hardcoded address that would go stale
            # the moment a patch changed a region's length.
            f.write("TNRE%-4dEQU     *\n" % i)
            if bank != "BOTH":
                f.write("        ENDIF\n")

            if (lo, hi) in EXPORT:
                f.write("        IF      TNBANK <> BANK%s\n" % bank)
                f.write("; The other bank needs these ADDRESSES but not these bytes.\n")
                for name, a in sorted(syms.items(), key=lambda kv: kv[1]):
                    if lo <= a < hi:
                        f.write("%-8sEQU     $%04X\n" % (name, a - REBASE))
                f.write("        ENDIF\n")

    # A BOTH region is emitted into every bank, so it counts against every
    # bank's 2048 -- reporting it as its own line would understate both.
    sizes = {"GAME": 0, "KERN": 0}
    for i, (lo, hi, bank, _why, _kind) in enumerate(REGIONS):
        n = hi - lo
        if bank == "BOTH":
            for b in sizes:
                sizes[b] += n
        else:
            sizes[bank] += n
    print("mkbanks: %s" % ", ".join(
        "%s %d bytes (%d spare)" % (b, n, 0x800 - n) for b, n in sorted(sizes.items())))


if __name__ == "__main__":
    main()
