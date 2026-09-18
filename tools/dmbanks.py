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

# Where each bank is entered, in order of entry index. DMGOTO carries the
# index in Y and every bank's $1000 dispatcher reads it.
#
# Stock's $F000 `JMP LF0CA` is in no bank -- dmphase excludes it -- so $1000 is
# free for the dispatcher, and it can be as long as it needs to be rather than
# the three bytes the siblings had to squeeze into.
ENTRIES = {
    "G0": [(0xF0E4, "the top of the frame"),
           (0xF22B, "resume, after the dot engine")],
    "G1": [(0xF859, "the dot engine")],
    "G2": [(0xF244, "the vblank spin, then the picture")],
    "G3": [(0xF420, "the overscan band"),
           (0xF0CA, "the cold path")],
}

# Banks that read the synthetic controller, and therefore have to fill it at
# the head of their band. The shadows are band-local and do not survive the
# kernel; see src/dmmix.inc.
NEEDS_MIX = {"G0", "G1", "G3"}

# The bank-local switch stubs the seam patches jump to. A branch cannot reach
# another bank, but it can reach one of these.
STUBS = {
    "G0": [("DMTOG1", "BANKG1", 0, "into the dot engine"),
           ("DMTOG2", "BANKG2", 0, "into the kernel -- the fall-through at $F243")],
    "G1": [("DMTOG0R", "BANKG0", 1, "back to G0, resuming after the dot engine")],
    "G2": [("DMTOG3", "BANKG3", 0, "into the overscan band")],
    "G3": [("DMTOG0", "BANKG0", 0, "to the top of the next frame")],
}

# Regions that run off their end into another bank, with no reference for the
# assembler to catch. The switch is appended after the region.
FALLTHROUGH = {
    ("G0", 0xF243): ("DMTOG2", "the vblank band ends; the kernel is in G2"),
    ("G3", 0xF0E3): ("DMTOG0", "the cold path falls into the frame top, in G0"),
}

WINDOW = 0x1000
BANK_SIZE = 0x800

# PINNED TABLES, and the bug that makes them necessary.
#
# A table reached through a ZERO-PAGE POINTER must be at the same address in
# every bank that touches it, because the pointer crosses the bank boundary
# and the address does not mean anything on the other side.
#
# Dodge 'Em's digit pointers are BUILT in G0 (LFC41, LFC71) and DEREFERENCED in
# G2, the display kernel. Packed, LFE94 landed at $143A in G0 and $12B5 in G2 --
# so the kernel followed a pointer into whatever G2 happened to have at $143A.
# The picture still drew; it drew the wrong bytes.
#
# Absolute references do not have this problem: they are resolved per bank by
# the assembler and never leave it. Only what travels through RAM does.
#
# So the span containing every pointer target is placed at a FIXED address in
# every bank that carries any of it, identically, and the packed regions have
# to fit below it.
# Computed, not chosen: the span is the union of every region, in any bank,
# that contains a pointer target, and it is placed hard against the top of the
# bank so the packed code has the rest.
def pin_span():
    lo = hi = None
    for b in BANK_REGIONS:
        for l, h in BANK_REGIONS[b]:
            if any(l <= t <= h for t in POINTER_TARGETS):
                lo = l if lo is None else min(lo, l)
                hi = h if hi is None else max(hi, h)
    return lo, hi
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


def insert_table():
    """stock address -> source line to emit BEFORE the line at that address."""
    return {a: (src, why) for a, src, why in getattr(patchmap, "INSERTS", [])}


def assert_line_boundaries(addrs, regions, what):
    """EVERY REGION BOUNDARY MUST FALL ON A SOURCE-LINE BOUNDARY.

    A region that starts nine bytes into a DB does not start where its ORG
    says: the emitter can only place whole source lines, so it skips that line
    entirely and everything after it sits at the wrong address. The symptom is
    a table that is fine in three banks and adrift in the fourth.
    """
    starts = {a for a, _ in addrs.values()}
    ends = {a + nb for a, nb in addrs.values()}
    bad = []
    for lo, hi in regions:
        if lo not in starts:
            bad.append("$%04X (%s start) is inside a source line" % (lo, what))
        if hi + 1 not in ends and hi != 0xFFFF:
            bad.append("$%04X (%s end) is inside a source line" % (hi, what))
    return bad


def main():
    lst, asm, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    addrs = line_addresses(lst)
    src = open(asm).read().splitlines()
    patched = patch_table()
    inserts = insert_table()
    used_ins = set()

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
        pin_lo, pin_hi = pin_span()
        PIN_BASE = WINDOW + BANK_SIZE - (pin_hi - pin_lo + 1)

        # The runs this bank EFFECTIVELY carries: its packed ones plus, if it
        # touches the pinned span at all, the whole of that span. The anchors
        # below must be computed against these and not against the raw region
        # list -- G1's raw run began at $FE64, nine bytes into the DB at
        # $FE5B, so the nearest-preceding-label search could not see LFE5B and
        # anchored LFE6C on a code label instead. It assembled, and put a
        # pointer to the middle of the dot engine in $A7.
        wants_pin = pin_lo is not None and any(
            r[0] <= pin_hi and r[1] >= pin_lo for r in runs)
        eff_runs = list(runs) + ([(pin_lo, pin_hi)] if wants_pin else [])

        real_labels = set()
        for n in sorted(addrs):
            lab = label_of(src[n - 1])
            if lab:
                real_labels.add(lab)

        anchors = []
        for t in POINTER_TARGETS:
            if not any(lo <= t <= hi for lo, hi in eff_runs):
                continue
            if ("L%04X" % t) in real_labels:
                continue            # DiStella already names it
            best = None
            for n in sorted(addrs):
                a, _ = addrs[n]
                if a <= t and any(lo <= a <= hi for lo, hi in eff_runs):
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

        # ---- the entry dispatcher, at $1000 ----
        # Which of this bank's runs are pinned: any that overlaps a pointer
        # target's containing table.

        cursor = WINDOW
        ents = ENTRIES[bank]
        out.append("        ORG     $%04X" % WINDOW)
        out.append("; bank entry. DMGOTO leaves the entry index in Y.")
        dispatch = []
        if len(ents) == 1:
            dispatch.append("        jmp     L%04X           ; %s"
                            % (ents[0][0], ents[0][1]))
        else:
            for i, (tgt, why) in enumerate(ents[1:], 1):
                dispatch.append("        cpy     #%d" % i)
                dispatch.append("        beq     DMEN%d" % i)
            dispatch.append("        jmp     L%04X           ; entry 0: %s"
                            % (ents[0][0], ents[0][1]))
            for i, (tgt, why) in enumerate(ents[1:], 1):
                dispatch.append("DMEN%d:  jmp     L%04X           ; entry %d: %s"
                                % (i, tgt, i, why))
        out.extend(dispatch)
        cursor += sum(3 if l.strip().startswith(("jmp", "DMEN", "jsr")) else 2
                      for l in dispatch)

        # ---- the bank-local switch stubs ----
        for name, bk, ent, why in STUBS.get(bank, []):
            out.append("%s: lda     #%s           ; %s" % (name, bk, why))
            out.append("        ldy     #%d" % ent)
            out.append("        jmp     DMGOTO")
            cursor += 7

        # ONE ORG, at $1000, and everything after it flows on.
        #
        # The first version gave each region its own ORG at a cursor this file
        # computed from the STOCK size of every line. That is wrong the moment
        # a patch changes size, and several do: four RTS sites become jumps,
        # the evicted reads become absolute, and the kernel's exit branch is
        # inverted over a jump. The cursor undercounted by three and the next
        # region was ORG'd three bytes inside the previous one -- which AS
        # reports as "overlapping memory allocation" and then silently lets the
        # later write win.
        #
        # So the sizes are not computed here at all. The assembler packs them,
        # which it is for, and tools/checkbanks.py reads the real figure off
        # the listing afterwards.
        # A bank that carries ANY of the pinned span carries ALL of it, at the
        # same address. Two reasons, and the second is the one that bit:
        #
        #   * identical addresses are the entire point -- a pointer built in
        #     one bank is dereferenced in another;
        #   * a per-bank sub-span does not start where its ORG says it does.
        #     G1's run began at $FE64, which is 9 bytes INTO the DB at $FE5B,
        #     so the emitter skipped that whole line and LFE94 came out seven
        #     bytes adrift of the other three banks.
        #
        # Tennis's mkbanks.py has a rule for the second one -- every region
        # boundary must fall on a source-line boundary -- and it is asserted
        # below rather than merely honoured here.
        pinned = [(pin_lo, pin_hi)] if wants_pin else []
        packed = [r for r in runs
                  if not (wants_pin and r[0] <= pin_hi and r[1] >= pin_lo)]
        for lo, hi in packed:
            out.append("; ---- stock $%04X-$%04X ----" % (lo, hi))
            for n in sorted(addrs):
                a, nb = addrs[n]
                if not lo <= a <= hi:
                    continue
                _ = nb
                if a in inserts:
                    ins, why = inserts[a]
                    used_ins.add(a)
                    out.append("%s        ; INSERTED: %s" % (ins, why))
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
                    head, _, tail = new.partition("\n")
                    line = "%-7s %-24s; PATCHED: %s" % (lab or "", head, why)
                    if tail:
                        line = line + "\n" + tail
                out.append(line)
                cursor += nb
            ft = FALLTHROUGH.get((bank, hi))
            if ft:
                out.append("        jmp     %-15s ; SEAM: %s" % (ft[0], ft[1]))
                cursor += 3
        # DMPOKED/DMPOKEB are leaves, called from three of the four banks.
        # A bank that is not mapped cannot be called into, so each caller
        # carries its own copy -- Dragster's PORTING.md 4, where StageRace
        # jumped into the middle of PositionSprites and 72 bytes had to live
        # in both banks. Fifty bytes here, against hundreds spare.
        if bank in NEEDS_MIX:
            out.append("")
            out.append('        INCLUDE "dmmix.inc"')
        if any("DMPOKE" in l for l in out):
            out.append("")
            out.append('        INCLUDE "dmpoke.inc"')
            cursor += DMPOKE_SIZE

        # ---- the pinned tables, at the same address in every bank ----
        #
        # LAST. This ORGs to the top of the bank, so anything emitted after it
        # continues past $1800 -- which p2bin truncates without a word, and
        # checkbanks.py is what says so. The shared leaf routines above have to
        # be placed before it, in the packed region.
        for lo, hi in pinned:
            at = PIN_BASE + (lo - pin_lo)
            out.append("")
            out.append("; ---- stock $%04X-$%04X, PINNED at $%04X ----"
                       % (lo, hi, at))
            out.append("; Reached through a zero-page pointer that crosses a")
            out.append("; bank, so this must be at one address everywhere.")
            out.append("        ORG     $%04X" % at)
            for n in sorted(addrs):
                a, nb = addrs[n]
                if not lo <= a <= hi:
                    continue
                line = src[n - 1]
                if a in patched:
                    new, why = patched[a]
                    used.add(a)
                    lab = label_of(line)
                    head, _, tail = new.partition("\n")
                    line = "%-7s %-24s; PATCHED: %s" % (lab or "", head, why)
                    if tail:
                        line = line + "\n" + tail
                out.append(line)
            end = PIN_BASE + (hi - pin_lo)
            if end >= WINDOW + BANK_SIZE:
                sys.exit("dmbanks: bank %s pinned span runs past the bank at "
                         "$%04X" % (bank, end))
            if at < cursor:
                sys.exit("dmbanks: bank %s packs to $%04X, over the pinned "
                         "span at $%04X -- PIN_BASE must rise or the bank must "
                         "shrink" % (bank, cursor, at))


        # A stock-size estimate only: what this bank would be if no patch
        # changed length. checkbanks.py has the real number.
        size = cursor - WINDOW
        report.append((bank, len(runs), size))
        path = "%s/dm%s.asm" % (outdir, bank.lower())
        open(path, "w").write("\n".join(out) + "\n")

    print("dmbanks: bank   regions   est.    of %d  (checkbanks has the real"
          " figure)" % BANK_SIZE)
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

    bad = assert_line_boundaries(addrs, [pin_span()], "the pinned span")
    if bad:
        for b in bad:
            print("dmbanks: " + b)
        sys.exit("dmbanks: FAIL -- a region boundary is not a line boundary")

    miss_ins = sorted(set(inserts) - used_ins)
    if miss_ins:
        print("dmbanks: %d declared INSERT(s) landed in no bank:" % len(miss_ins))
        for a in miss_ins:
            print("    $%04X  %s" % (a, inserts[a][1]))
        bad = True

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
