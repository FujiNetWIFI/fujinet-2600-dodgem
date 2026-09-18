#!/usr/bin/env python3
"""dmbanks.py -- carve Dodge 'Em into the cartridge's banks.

A FujiNet bank is the 2K at $1000-$17FF; the 2K above it is the cartridge's
mailbox, of which the client owns only the 220-byte tail. Dodge 'Em is 4096
bytes of a game that uses all 128 bytes of RAM, so it does not merely fail to
fit a bank -- it fails to fit two, once every subroutine each frame phase calls
and every table it reads is counted.

WHAT IS DIFFERENT FROM THE SIBLINGS, and it is the whole design:

  Combat, Video Olympics, Dragster and Tennis were 2048-byte games. Every byte
  could keep the address it had, rebased $F000 -> $1000 by one constant, and
  each bank simply left the other's regions empty. Every absolute JMP/JSR
  target stayed byte-identical and check_patch.py could be a real byte audit.

  That cannot work here. Stock $F000-$F7FF and $F800-$FFFF both rebase into the
  SAME 2K window, so any bank carrying code from both halves has two regions
  competing for one address. And the phase footprints all span both halves --
  G1 is the dot engine at $F859 plus its tables at $FE**.

So the regions are PACKED instead: each bank's runs are laid end to end from
$1000, and the assembler resolves the labels. Nothing is relocated by hand,
because nothing needs to be -- AS is already a relocating assembler and the
disassembly is already symbolic.

THE PROPERTY THAT MAKES THIS SAFE: a reference to a label that is NOT in this
bank does not silently resolve to the wrong address. It is an undefined symbol,
and the assembler enumerates every cross-bank seam for us rather than leaving
them to be discovered at run time as a jump into the middle of a table.

Usage: dmbanks.py <dm_org.lst> <dm_org.asm> <outdir>
"""
import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
sys.path.insert(0, "build")

import patches as patchmap
from dmregions import BANK_REGIONS

WINDOW = 0x1000
BANK_SIZE = 0x800
DMPOKE_SIZE = 0x30      # src/dmpoke.inc, measured; the build asserts it below

# AS lists at most nine emitted bytes and then puts ONE space before the
# source, so a pattern that expects two spaces after the byte column matches
# every instruction and silently drops every long DB. That is exactly the shape
# of bug that produces a bank with its code and none of its tables, which
# assembles as an undefined label rather than as a wrong picture -- but only
# because the labels happen to be referenced. Match the address column and
# nothing else.
LISTING = re.compile(r'^\s*(\d+)/\s*([0-9A-F]{4})\s*:\s*(\S.*)?$')
EMITS = re.compile(r'^[0-9A-F]{2}(\s|$)')


def line_addresses(lst, end=0x10000):
    """AS source line number -> (address, size in bytes).

    From the ASSEMBLER'S OWN listing, never from line numbers written down
    here: build/dm_org.lst is what `make verify-org` has just proved rebuilds
    the cartridge byte for byte, so a region boundary cannot drift away from
    the code it is meant to bound.

    The SIZE is the distance to the next emitting line, not a count of the
    bytes printed -- the listing shows only the first nine of them.
    """
    rows = []
    for ln in open(lst, errors='replace'):
        m = LISTING.match(ln)
        if not m or not m.group(3) or not EMITS.match(m.group(3)):
            continue
        rows.append((int(m.group(1)), int(m.group(2), 16)))
    rows.sort()
    out = {}
    for i, (n, a) in enumerate(rows):
        nxt = rows[i + 1][1] if i + 1 < len(rows) else end
        out[n] = (a, max(nxt - a, 0))
    return out


# The pointer targets are addresses the game reaches only through a zero-page
# pointer, so nothing refers to them absolutely and DiStella emits no label --
# and two of the three fall INSIDE a DB run, so no label can be emitted at them
# either. They are defined here as an offset from the nearest preceding label,
# which is a thing the assembler can compute and a thing that survives the
# tables being repacked.
POINTER_TARGETS = (0xFE64, 0xFE6C, 0xFE94)


def label_of(line):
    """The label a source line defines, or None. A label is a leading token in
    column 0; anything indented is a bare instruction."""
    if not line or line[0].isspace() or line.lstrip().startswith(';'):
        return None
    return line.split()[0].rstrip(':')


def patch_table():
    """stock address -> replacement source line."""
    out = {}
    for _, entries in patchmap.ALL:
        for addr, _want, new, why in entries:
            out[addr] = (new, why)
    return out


def main():
    lst, asm, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    addrs = line_addresses(lst)
    src = open(asm).read().splitlines()
    patched = patch_table()

    # The preamble: everything before the first ORG -- CPU, the TIA equates,
    # the header comments. Every bank needs it and none of it emits a byte.
    first = min(n for n in addrs)
    preamble = [l for l in src[:first - 1] if not l.strip().startswith('ORG')]

    used = set()
    report = []
    for bank in sorted(BANK_REGIONS):
        runs = BANK_REGIONS[bank]
        out = list(preamble)
        out.append("")
        out.append("; ==== bank %s: %d regions, packed from $%04X ====" %
                   (bank, len(runs), WINDOW))
        out.append('        INCLUDE "fujinet.inc"')
        out.append('        INCLUDE "dmdefs.inc"')
        out.append("")
        # Synthesise the pointer-target labels this bank can define.
        real_labels = set()
        for n in sorted(addrs):
            lab = label_of(src[n - 1])
            if lab:
                real_labels.add(lab)

        anchors = []
        for t in POINTER_TARGETS:
            if not any(lo <= t <= hi for lo, hi in runs):
                continue
            if ("L%04X" % t) in real_labels:
                continue            # DiStella already names it
            best = None
            for n in sorted(addrs):
                a, _ = addrs[n]
                if a <= t and any(lo <= a <= hi for lo, hi in runs):
                    lab = label_of(src[n - 1])
                    if lab:
                        best = (lab, t - a)
            if best is None:
                sys.exit("dmbanks: bank %s carries $%04X but has no label "
                         "before it to anchor on" % (bank, t))
            anchors.append("LF%03X   EQU     %s+%d" % (t & 0xFFF, best[0], best[1])
                           if False else
                           "L%04X  EQU     %s+%d" % (t, best[0], best[1]))
        if anchors:
            out.append("; pointer targets: reached only through a zero-page")
            out.append("; pointer, so nothing names them and two fall inside a")
            out.append("; DB run. Anchored on the nearest preceding label.")
            out.extend(anchors)
            out.append("")

        cursor = WINDOW
        for lo, hi in runs:
            out.append("        ORG     $%04X       ; stock $%04X-$%04X"
                       % (cursor, lo, hi))
            for n in sorted(addrs):
                a, nb = addrs[n]
                if not lo <= a <= hi:
                    continue
                line = src[n - 1]
                if a in patched:
                    new, why = patched[a]
                    used.add(a)
                    # KEEP THE LABEL. A patch replaces an instruction, never
                    # the name of the place it sits at -- and better than half
                    # the input sites are branch targets, so dropping the label
                    # turns each one into an undefined symbol somewhere else
                    # entirely, which reads as a missing bank rather than as a
                    # broken patch.
                    lab = label_of(line)
                    line = "%-7s %-24s; PATCHED: %s" % (lab or "", new, why)
                out.append(line)
                cursor += nb
        # DMPOKED/DMPOKEB are leaves, called from three of the four banks.
        # A bank that is not mapped cannot be called into, so each caller
        # carries its own copy -- Dragster's PORTING.md 4, where StageRace
        # jumped into the middle of PositionSprites and 72 bytes had to live
        # in both banks. Fifty bytes here, against hundreds spare.
        if any("DMPOKE" in l for l in out):
            out.append("")
            out.append("        ORG     $%04X" % cursor)
            out.append('        INCLUDE "dmpoke.inc"')
            cursor += DMPOKE_SIZE

        size = cursor - WINDOW
        report.append((bank, len(runs), size))
        path = "%s/dm%s.asm" % (outdir, bank.lower())
        open(path, "w").write("\n".join(out) + "\n")

    print("dmbanks: bank   regions   bytes   of %d" % BANK_SIZE)
    bad = False
    for bank, nr, size in report:
        flag = "%d spare" % (BANK_SIZE - size)
        if size > BANK_SIZE:
            flag = "OVER by %d" % (size - BANK_SIZE)
            bad = True
        print("dmbanks:  %-4s   %5d   %5d   %s" % (bank, nr, size, flag))

    # FALL-THROUGH SEAMS, which the undefined-symbol check cannot see.
    #
    # Packing the regions makes every cross-bank REFERENCE an undefined symbol,
    # and the assembler names each one. It says nothing about a region whose
    # last instruction simply runs off the end into the next region, because
    # there is no symbol involved -- and on this cartridge that does not run
    # into the next region, it runs into whatever the packer put there.
    #
    # $F243 is one: the vblank band ends and the kernel begins at $F244, in a
    # different bank, with no instruction between them. Found here, it is a
    # line of output; found later, it is a jump into the middle of a table.
    STOPS = {0x4C, 0x60, 0x40, 0x6C}       # JMP abs, RTS, RTI, JMP (ind)
    rom = open("rom/dodgem.bin", "rb").read()
    rbase = 0x10000 - len(rom)
    owner = {}
    for b in BANK_REGIONS:
        for lo, hi in BANK_REGIONS[b]:
            for a in range(lo, hi + 1):
                owner.setdefault(a, set()).add(b)

    seams = []
    for b in sorted(BANK_REGIONS):
        for lo, hi in BANK_REGIONS[b]:
            nxt = hi + 1
            if nxt > 0xFFFF or b in owner.get(nxt, set()):
                continue
            last = None
            for n in sorted(addrs):
                a, nb = addrs[n]
                if a <= hi < a + nb:
                    last = a
            if hi >= 0xFD62:
                continue           # data: adjacent tables, not control flow
            if last is None or rom[last - rbase] in STOPS:
                continue
            seams.append((b, hi, nxt, sorted(owner.get(nxt, {"nothing"}))))

    if seams:
        print("dmbanks: %d FALL-THROUGH seam(s) -- control leaves the bank "
              "with no reference for the" % len(seams))
        print("dmbanks: assembler to catch. Each needs a bank switch, not a "
              "trampoline call:")
        for b, hi, nxt, to in seams:
            print("    %s runs off $%04X into $%04X (%s)"
                  % (b, hi, nxt, "/".join(to)))

    missing = sorted(set(patched) - used)
    if missing:
        print("dmbanks: %d declared patch sites landed in NO bank:" % len(missing))
        for a in missing:
            print("    $%04X  %s" % (a, patched[a][1]))
        bad = True

    if bad:
        sys.exit("dmbanks: FAIL")
    print("dmbanks: every bank fits and every declared patch landed")


if __name__ == '__main__':
    main()
