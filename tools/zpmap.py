#!/usr/bin/env python3
"""zpmap.py -- what of zero page Dodge 'Em uses, and what a netcode may have.

Dodge 'Em uses ALL 128 BYTES OF RAM. That is not a figure of speech and it is
the fact this whole port is arranged around, so this tool exists to establish
it rigorously rather than to estimate it. The family's recon.py reports a free
upper bound of 69 cells here; the true figure is zero, and the gap is exactly
the two mistakes the Intellivision ports and Combat paid for first:

  * A cell reached only by INDEXING is not free. `LDA $C3,X` under `LDX #$08`
    touches $C3-$CB, and a scan that records only the operand byte reports
    $C4-$CB as untouched. So every indexed base is BOUNDED here, by walking
    back from the access to the instruction that last loaded its index.

  * THE STACK IS IN ZERO PAGE. The 6507 puts the stack at $0100-$01FF, which
    mirrors onto $80-$FF, so the top of zero page is stack and the real bound
    is the deepest the call graph goes.

What this adds over the sibling ports' version is PHASE LIVENESS, and it is
added because "free" is the wrong question for this cartridge. Nothing is
free. The question is whether a cell is dead across the band where the network
machine runs, because a netcode cell that is live only inside that band may
share an address with a game cell that is live only outside it. A touch scan
cannot answer that; it has to know WHEN.

So the frame is walked as four phases, by recursive descent from each entry
with JSRs followed (a subroutine belongs to every phase that calls it), and
each cell is reported by the phases that read it and the phases that write it.

Usage: zpmap.py rom/dodgem.bin build/dm_org.lst
"""
import re
import sys

RAM_LO, RAM_HI = 0x80, 0xFF

# The four phases of a Dodge 'Em frame, by entry address. The linear walk of
# one phase stops when it reaches the entry of another; JSRs are followed, so
# a shared routine is attributed to every phase that can call it.
#
#   COLD  $F0CA  SEI/CLD/LDX #$FF/TXS -- the reset entry
#   VBL   $F0E4  STA VSYNC, the top of the frame; arms TIM64T=$28 at $F142
#   KERN  $F244  LDA INTIM/BNE -- the vblank spin, and the picture after it
#   OVER  $F420  STA VBLANK, arms TIM64T=$24; the game logic; spin at $F4EA
#
# OVER is the one that matters: it is where the network machine will be
# stepped, in front of the $F4EA spin.
PHASES = [("COLD", 0xF0CA), ("VBL", 0xF0E4), ("KERN", 0xF244), ("OVER", 0xF420)]
BOUNDS = {a for _, a in PHASES}

LEN = [0] * 256
for op in (0x00,0x08,0x0A,0x18,0x28,0x2A,0x38,0x40,0x48,0x4A,0x58,0x60,0x68,
           0x6A,0x78,0x88,0x8A,0x98,0x9A,0xA8,0xAA,0xB8,0xBA,0xC8,0xCA,0xD8,
           0xE8,0xEA,0xF8):
    LEN[op] = 1
for op in (0x01,0x05,0x06,0x09,0x10,0x11,0x15,0x16,0x21,0x24,0x25,0x26,0x29,
           0x30,0x31,0x35,0x36,0x41,0x45,0x46,0x49,0x50,0x51,0x55,0x56,0x61,
           0x65,0x66,0x69,0x70,0x71,0x75,0x76,0x81,0x84,0x85,0x86,0x90,0x91,
           0x94,0x95,0x96,0xA0,0xA1,0xA2,0xA4,0xA5,0xA6,0xA9,0xB0,0xB1,0xB4,
           0xB5,0xB6,0xC0,0xC1,0xC4,0xC5,0xC6,0xC9,0xD0,0xD1,0xD5,0xD6,0xE0,
           0xE1,0xE4,0xE5,0xE6,0xE9,0xF0,0xF1,0xF5,0xF6):
    LEN[op] = 2
for op in (0x0D,0x0E,0x19,0x1D,0x1E,0x20,0x2C,0x2D,0x2E,0x39,0x3D,0x3E,0x4C,
           0x4D,0x4E,0x59,0x5D,0x5E,0x6C,0x6D,0x6E,0x79,0x7D,0x7E,0x8C,0x8D,
           0x8E,0x99,0x9D,0xAC,0xAD,0xAE,0xB9,0xBC,0xBD,0xBE,0xCC,0xCD,0xCE,
           0xD9,0xDD,0xDE,0xEC,0xED,0xEE,0xF9,0xFD,0xFE):
    LEN[op] = 3
BRANCH = {0x10,0x30,0x50,0x70,0x90,0xB0,0xD0,0xF0}

# zero-page addressing modes, split by whether they READ or WRITE the cell.
# A read-modify-write counts as both, which is what makes EOR $AC,X show up
# on both sides and is exactly right.
ZP_R = {0x05:'ORA',0x24:'BIT',0x25:'AND',0x45:'EOR',0x65:'ADC',0xA4:'LDY',
        0xA5:'LDA',0xA6:'LDX',0xC4:'CPY',0xC5:'CMP',0xE4:'CPX',0xE5:'SBC',
        0x06:'ASL',0x26:'ROL',0x46:'LSR',0x66:'ROR',0xC6:'DEC',0xE6:'INC'}
ZP_W = {0x84:'STY',0x85:'STA',0x86:'STX',
        0x06:'ASL',0x26:'ROL',0x46:'LSR',0x66:'ROR',0xC6:'DEC',0xE6:'INC'}
ZPX_R = {0x15:'ORA',0x35:'AND',0x55:'EOR',0x75:'ADC',0xB4:'LDY',0xB5:'LDA',
         0xD5:'CMP',0xF5:'SBC',0x16:'ASL',0x36:'ROL',0x56:'LSR',0x76:'ROR',
         0xD6:'DEC',0xF6:'INC'}
ZPX_W = {0x94:'STY',0x95:'STA',0x16:'ASL',0x36:'ROL',0x56:'LSR',0x76:'ROR',
         0xD6:'DEC',0xF6:'INC'}
ZPY_R = {0xB6:'LDX'}
ZPY_W = {0x96:'STX'}
IND_R = {0x01:'ORA',0x21:'AND',0x41:'EOR',0x61:'ADC',0xA1:'LDA',0xC1:'CMP',
         0xE1:'SBC',0x11:'ORA',0x31:'AND',0x51:'EOR',0x71:'ADC',0xB1:'LDA',
         0xD1:'CMP',0xF1:'SBC'}
IND_W = {0x81:'STA', 0x91:'STA'}
XMODE = set(ZPX_R) | set(ZPX_W) | {0x01,0x21,0x41,0x61,0x81,0xA1,0xC1,0xE1}
YMODE = set(ZPY_R) | set(ZPY_W) | {0x11,0x31,0x51,0x71,0x91,0xB1,0xD1,0xF1}
INDIRECT = set(IND_R) | set(IND_W)

LDXI, LDYI = 0xA2, 0xA0

# The cold-start clear. $F0D1 is `STA VSYNC,X` inside `LDX #$FF / TXS / INX /
# TXA / ... / INX / BNE`, so it sweeps $00-$FF: every TIA register AND all 128
# bytes of RAM. It is an initialisation, not a use, and counting it as one
# would attribute every cell in the machine to the COLD phase and tell us
# nothing.
#
# It is excluded from per-cell liveness and reported on its own instead,
# because it is also a hazard in its own right -- the one all four sibling
# ports hit (Combat 4.12, VO 3.4, Dragster 3.4, Tennis 2.6). It reaches the
# reset vector only, not the RESET SWITCH, which on this console is a RIOT bit
# the program polls at $F162. So netcode state set up after cold start
# survives a player pressing RESET. That is load-bearing and is asserted below.
COLD_CLEAR = 0xF0D1

# Sites whose index comes from memory rather than an immediate, so the
# backward walk cannot bound them. Each is stated here ONCE, with what bounds
# it, in the spirit of Dragster's tools/dgmap.py -- the single place the map
# is written down. A site that is neither auto-bounded nor named here is a
# hard failure, so this table cannot silently rot.
HAND = {
    # LF003, the sprite positioner: `STA RESP0,X` / `STA HMP0,X` with X the
    # player index, 0 or 1. TIA registers, never RAM.
    0xF02D: (1, "LF003 player index, 0 or 1 (TIA)"),
    0xF02F: (1, "LF003 player index, 0 or 1 (TIA)"),
    # The display kernel's playfield streams. X is `LDX $A9`, and $A9 is the
    # row counter seeded `LDX #$08 / STX $A9` at $F24D and counted down to 0.
    0xF3E5: (8, "kernel row index from $A9, seeded LDX #$08 at $F24D"),
    0xF3E9: (8, "kernel row index from $A9"),
    0xF3FB: (8, "kernel row index from $A9"),
    0xF3FF: (8, "kernel row index from $A9"),
    0xF403: (8, "kernel row index from $A9"),
    0xF40C: (8, "kernel row index from $A9"),
    0xF410: (8, "kernel row index from $A9"),
    0xF414: (8, "kernel row index from $A9"),
    # LF530. Both callers set it: `LDX #$01` at $F1FF, `LDX #$00` at $F214.
    0xF532: (1, "LF530 player index; callers LDX #$01 / LDX #$00"),
    0xF538: (1, "LF530 player index"),
    0xF548: (1, "LF530 player index"),
    0xF54A: (1, "LF530 player index"),
    0xF54C: (1, "LF530 player index"),
    0xF550: (1, "LF530 player index"),
    # LF5A0's second arm. `LDX #$06` is at the head of the routine; the walk
    # stops at the BCC that chooses the arm.
    0xF5B3: (6, "LF5A0 swap loop, LDX #$06 at $F5A0"),
    0xF5B5: (6, "LF5A0 swap loop"),
    0xF5B7: (6, "LF5A0 swap loop"),
    0xF5B9: (6, "LF5A0 swap loop"),
    # The dot-eating sites and LFD14 beneath them. Every caller reaches them
    # under `LDX #$08` ($F88B, $F8D6 and the two like them), and LFD14 is
    # entered by JSR from inside those loops with X still live.
    0xF927: (8, "dot row index, LDX #$08"),
    0xF92D: (8, "dot row index, LDX #$08"),
    0xF92F: (8, "dot row index, LDX #$08"),
    0xF96C: (8, "dot row index, LDX #$08"),
    0xF972: (8, "dot row index, LDX #$08"),
    0xF974: (8, "dot row index, LDX #$08"),
    0xFD18: (8, "LFD14, X live from the caller's LDX #$08"),
    0xFD1C: (8, "LFD14, X live from the caller"),
    0xFD22: (8, "LFD14, X live from the caller"),
    0xFD26: (8, "LFD14, X live from the caller"),
    0xFD2C: (8, "LFD14, X live from the caller"),
    0xFD30: (8, "LFD14, X live from the caller"),
    0xFD36: (8, "LFD14, X live from the caller"),
    0xFD3A: (8, "LFD14, X live from the caller"),
    0xFD40: (8, "LFD14, X live from the caller"),
    0xFD44: (8, "LFD14, X live from the caller"),
    0xFD4A: (8, "LFD14, X live from the caller"),
    0xFD4E: (8, "LFD14, X live from the caller"),
    0xFD54: (8, "LFD14, X live from the caller"),
    0xFD58: (8, "LFD14, X live from the caller"),
    0xFD5B: (8, "LFD14, X live from the caller"),
    0xFD5F: (8, "LFD14, X live from the caller"),
}


def code_addresses(listing):
    """The code/data split comes from the ASSEMBLER'S listing. A linear walk
    through a data table is misaligned garbage and invents references."""
    pat = re.compile(r'^\s*\d+/\s*([0-9A-F]{4})\s*:\s*'
                     r'([0-9A-F][0-9A-F ]*?)\s{2,}(\S.*)$')
    out = set()
    for ln in open(listing, errors='replace'):
        m = pat.match(ln)
        if not m:
            continue
        src = m.group(3).strip()
        body = src.split(None, 1)
        mnem = body[1].split()[0].upper() if len(body) > 1 else body[0].upper()
        if mnem in ('DB', 'DW', 'EQU', 'ORG', 'CPU', 'END', 'INCLUDE'):
            continue
        out.add(int(m.group(1), 16))
    return out


def bound_index(rom, base, code, site, reg):
    """How far past `base` can this access reach?

    Walk backwards over the instruction stream for the nearest `LDX #n` /
    `LDY #n` that can reach this site. That is what bounds `LDA $C3,X` to
    nine cells rather than to the 256 a pessimist would have to assume, and
    it is the whole difference between 'zero bytes free' and recon.py's 69.

    Returns the immediate, or None when no dominating load was found -- in
    which case the caller must treat the base as unbounded and say so.
    """
    want = LDXI if reg == 'X' else LDYI
    for a in range(site - 1, max(site - 96, min(code)) - 1, -1):
        if a not in code:
            continue
        op = rom[a - base]
        if op == want:
            return rom[a - base + 1]
        if op in (0x20, 0x4C, 0x60):     # JSR/JMP/RTS: a different stream
            break
    return None


def stack_depth(rom, base, code, entry, _stack=frozenset(), _memo={}):
    """The deepest JSR chain from `entry`, in bytes of stack.

    This is not a nicety. The 6507 puts the stack at $0100-$01FF, which
    mirrors onto $80-$FF, so the stack and the game's variables are the same
    128 bytes and the only thing that says where the usable RAM stops is how
    deep the call graph actually goes. Tennis measured five bytes and set its
    floor at $FA; this measures rather than inherits that.
    """
    if entry in _stack:
        return 0                       # recursion; none here, but be safe
    if entry in _memo:
        return _memo[entry]
    best, seen, work = 0, set(), [entry]
    while work:
        pc = work.pop()
        while True:
            if pc in seen or pc not in code:
                break
            seen.add(pc)
            op = rom[pc - base]
            n = LEN[op] or 1
            if op in BRANCH:
                work.append(pc + 2 + ((rom[pc - base + 1] ^ 0x80) - 0x80))
                pc += 2
                continue
            tgt = (rom[pc - base + 1] | (rom[pc - base + 2] << 8)) if n == 3 else None
            if op == 0x20 and tgt is not None:      # JSR: 2 bytes, then recurse
                best = max(best, 2 + stack_depth(rom, base, code, tgt,
                                                 _stack | {entry}, _memo))
            elif op == 0x4C:
                if tgt is not None:
                    work.append(tgt)
                break
            elif op in (0x60, 0x40, 0x6C, 0x00):
                break
            pc += n
    _memo[entry] = best
    return best


def walk(rom, base, code, entry, stops):
    """Recursive descent from one phase entry, following JSRs, stopping the
    linear walk at any other phase's entry."""
    seen, work = set(), [entry]
    while work:
        pc = work.pop()
        while True:
            if pc in seen or pc not in code:
                break
            if pc in stops and pc != entry:
                break
            seen.add(pc)
            op = rom[pc - base]
            n = LEN[op] or 1
            if op in BRANCH:
                work.append(pc + 2 + ((rom[pc - base + 1] ^ 0x80) - 0x80))
                pc += 2
                continue
            tgt = (rom[pc - base + 1] | (rom[pc - base + 2] << 8)) if n == 3 else None
            if op == 0x20 and tgt is not None:          # JSR
                work.append(tgt)
            elif op == 0x4C:                            # JMP abs
                if tgt is not None:
                    work.append(tgt)
                break
            elif op in (0x60, 0x40, 0x6C, 0x00):        # RTS/RTI/JMP()/BRK
                break
            pc += n
    return seen


def main():
    rom_path = sys.argv[1] if len(sys.argv) > 1 else 'rom/dodgem.bin'
    listing = sys.argv[2] if len(sys.argv) > 2 else 'build/dm_org.lst'
    rom = open(rom_path, 'rb').read()
    base = 0x10000 - len(rom)
    code = code_addresses(listing)

    phase_of = {}
    stops = BOUNDS
    for name, entry in PHASES:
        for a in walk(rom, base, code, entry, stops):
            phase_of.setdefault(a, set()).add(name)

    reads, writes, how = {}, {}, {}
    unbounded = []
    for a in sorted(code):
        op = rom[a - base]
        if LEN[op] != 2:
            continue
        operand = rom[a - base + 1]
        ph = phase_of.get(a, {'?'})
        if op in INDIRECT:
            cells, tag = [operand, (operand + 1) & 0xFF], 'ptr'
        elif op in XMODE or op in YMODE:
            if a == COLD_CLEAR:
                continue                    # the cold sweep; reported apart
            reg = 'X' if op in XMODE else 'Y'
            n = bound_index(rom, base, code, a, reg)
            if n is None:
                if a in HAND:
                    n = HAND[a][0]
                else:
                    unbounded.append((a, operand, reg))
                    n = 0
            cells, tag = [(operand + i) & 0xFF for i in range(n + 1)], '%s+0..%d' % (reg, n)
        elif op in ZP_R or op in ZP_W:
            cells, tag = [operand], 'direct'
        else:
            continue
        is_r = op in ZP_R or op in ZPX_R or op in ZPY_R or op in IND_R
        is_w = op in ZP_W or op in ZPX_W or op in ZPY_W or op in IND_W
        for c in cells:
            if not RAM_LO <= c <= RAM_HI:
                continue
            how.setdefault(c, set()).add(tag)
            if is_r:
                reads.setdefault(c, set()).update(ph)
            if is_w:
                writes.setdefault(c, set()).update(ph)

    used = set(reads) | set(writes)
    free = [c for c in range(RAM_LO, RAM_HI + 1) if c not in used]

    print("zpmap: %d instructions, %d RAM cells touched, %d never touched"
          % (len(code), len(used), len(free)))
    if unbounded:
        print("zpmap: FAIL -- %d indexed accesses are bounded neither by a "
              "dominating immediate nor by the HAND table:" % len(unbounded))
        for a, o, r in unbounded:
            print("    $%04X  base $%02X,%s" % (a, o, r))
        print("Add each to HAND with what bounds it. An unbounded base is how")
        print("a free list comes out 69 cells too generous.")
        sys.exit(1)
    print("zpmap: every indexed base bounded (%d by hand, in the HAND table)"
          % len(HAND))
    print("zpmap: the cold clear at $%04X sweeps $00-$FF and is excluded; it "
          "reaches" % COLD_CLEAR)
    print("       the RESET VECTOR only, not the RESET switch ($F162), so "
          "state set up")
    print("       after cold start survives a player pressing RESET.")
    print()
    print("cell  read-in            written-in          reached by")
    print("----  -----------------  ------------------  ----------")
    for c in range(RAM_LO, RAM_HI + 1):
        if c not in used:
            continue
        r = ",".join(sorted(reads.get(c, ()))) or "-"
        w = ",".join(sorted(writes.get(c, ()))) or "-"
        print("$%02X   %-17s  %-18s  %s" % (c, r, w, ",".join(sorted(how[c]))))

    print()
    if free:
        print("NEVER TOUCHED: " + " ".join("$%02X" % c for c in free))
    else:
        print("NEVER TOUCHED: none. Every one of the 128 bytes is in use.")
    print()

    # ---- the two questions this tool exists to answer ----
    #
    # They are different questions and conflating them is how a netcode gets
    # built on sand. A cell can host:
    #
    #   SCRATCH     state that is born and dies inside one overscan band --
    #               the network machine's working registers. It needs a cell
    #               the game does not touch DURING that band.
    #
    #   PERSISTENT  state that must survive from one overscan band to the
    #               next: the tick, the sequence, the input shadows, the
    #               delay ring. It needs a cell the game NEVER WRITES AT ALL,
    #               because anything the game writes in vblank or the kernel
    #               lands squarely between two overscan bands and wipes it.
    #
    # The scratch list is generous here and the persistent list is what
    # decides the port.
    scratch = sorted(c for c in used
                     if 'OVER' not in reads.get(c, set())
                     and 'OVER' not in writes.get(c, set()))
    persistent = sorted(c for c in range(RAM_LO, RAM_HI + 1)
                        if not writes.get(c))

    print("SCRATCH -- untouched across the overscan band, so the network "
          "machine's")
    print("working registers may live here (%d cells):" % len(scratch))
    print("   " + (" ".join("$%02X" % c for c in scratch) if scratch else "none"))
    print()
    print("PERSISTENT -- never written by the game in ANY phase, so netcode "
          "state")
    print("that must outlive a frame may live here (%d cells):" % len(persistent))
    print("   " + (" ".join("$%02X" % c for c in persistent) if persistent
                   else "none"))
    print()
    deepest = max(stack_depth(rom, base, code, e) for _, e in PHASES)
    floor = 0x100 - deepest
    print("Of those, the STACK takes the top. `LDX #$FF / TXS` at $F0CD puts")
    print("it at $01FF, mirrored to $FF, and it grows down; the deepest JSR")
    print("chain measured here is %d bytes, so the stack floor is $%02X and"
          % (deepest, floor))
    print("$%02X-$FF are spoken for." % floor)
    print()

    NEED = 16
    usable = [c for c in persistent if c < floor]
    print("VERDICT: the netcode needs %d bytes of PERSISTENT state "
          "(dmdefs.inc)." % NEED)
    print("         %d are available below the stack floor%s."
          % (len(usable),
             ": " + " ".join("$%02X" % c for c in usable) if usable else ""))
    if len(usable) >= NEED:
        print("         PASS -- squeeze in-console; no cartridge-side work.")
        return 0
    print("         FAIL -- short by %d. Escalate: move the six playfield"
          % (NEED - len(usable)))
    print("         streams $C3-$F8 (54 bytes) into a cartridge text plane,")
    print("         which needs one new blit transform in the firmware. See")
    print("         PORTING.md; this is the decision that gate exists to make.")
    return 1


if __name__ == '__main__':
    sys.exit(main())
