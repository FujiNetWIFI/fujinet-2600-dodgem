#!/usr/bin/env python3
"""dmstack.py -- how deep does the stack go, netcode included?

The 6507 puts the stack at $0100-$01FF, which mirrors onto $80-$FF, so on this
console the stack and the game's variables are the same 128 bytes. `make zp`
measured the GAME's deepest chain at 6 bytes and set the floor at $FA. The
netcode nests on top of that, and every byte it adds comes out of the cells
immediately below -- which are $F9 (DMTMP) and then $F8, the last byte of the
sixth playfield stream.

An overrun there does not crash. It corrupts the track, slowly, and only in a
match. Combat's PORTING.md 3.3 is the same shape from the other end: Battleship
leaked two bytes a poll and after thirty-five polls the stack had eaten its own
entry code.

So this walks the netcode's own entry points statically, over the BANK
listings, and reports the deepest chain each one can reach.

Usage: dmstack.py <listing.lst> [listing.lst ...]
"""
import re
import sys

# Entry points, and THE STACK DEPTH THE GAME IS AT WHEN EACH IS CALLED.
#
# That second number is the whole correctness of this tool, and the first
# version got it wrong: it added the netcode's deepest chain to the game's
# deepest chain and reported twelve bytes against six available. They do not
# add. They happen at different points in the frame, and each of these three
# is called with the stack EMPTY --
#
#   DMMIXV  $F145, in the frame loop, inside no JSR
#   DMMIXO  $F42B, likewise
#   DMWAIT  the kernel bank's entry dispatcher, just after a bank switch,
#           which does `ldx #$FF / txs` precisely because a switch is a jump
#           and nothing ever returns through one
#
# The pokes are the exception: they are called from inside the game's own code,
# so their cost really does sit on top of whatever depth the caller was at.
#
# The pokes' depth is MEASURED, not assumed to be the game's worst. The three
# families sit at:
#
#   $F054   inside LF032, which is reached by JSR          -> 2
#   $F5B5   inside LF5A0, reached by JSR from $F4DD        -> 2
#   $F89F.. inside LF859 -- which is no longer reached by a JSR at all. $F228
#           became a BANK SWITCH, and a switch resets the stack, so the dot
#           engine now runs at depth 0 and its pokes cost 2 rather than 8.
#
# Taking the game's worst-case 6 for all of them reported a failure that was
# not there. A bound that is pessimistic in the wrong place is still wrong.
POKE_DEPTH = 2
ENTRIES = [("DMMIXV", 0), ("DMMIXO", 0), ("DMWAIT", 0),
           ("DMPOKED", "poke"), ("DMPOKEB", "poke")]

LINE = re.compile(r'^\s*(?:\(\d+\)\s*)?\d+/([0-9A-F]{4})\s*:\s*'
                  r'((?:[0-9A-F]{2} )+)')
SYM = re.compile(r"\b([A-Z_][A-Z0-9_]*)\s*:\s*([0-9A-F]{4})\s+C\b")


def load(path):
    mem, syms = {}, {}
    for ln in open(path, errors="replace"):
        m = LINE.match(ln)
        if m:
            a = int(m.group(1), 16)
            for i, b in enumerate(m.group(2).split()):
                mem[a + i] = int(b, 16)
        for name, addr in SYM.findall(ln):
            syms[name] = int(addr, 16)
    return mem, syms


LEN = {}
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


def depth(mem, entry, stack=frozenset(), memo=None):
    """Deepest push-chain from `entry`, in bytes. JSR is 2, PHA/PHP 1."""
    if memo is None:
        memo = {}
    if entry in stack:
        return 0
    if entry in memo:
        return memo[entry]
    memo[entry] = 0
    best, seen, work = 0, set(), [entry]
    while work:
        pc = work.pop()
        local = 0
        while True:
            if pc in seen or pc not in mem:
                break
            seen.add(pc)
            op = mem[pc]
            n = LEN.get(op, 1)
            if op in (0x48, 0x08):                 # PHA / PHP
                local += 1
                best = max(best, local)
            elif op in (0x68, 0x28):               # PLA / PLP
                local = max(local - 1, 0)
            if op in BRANCH:
                work.append(pc + 2 + ((mem.get(pc + 1, 0) ^ 0x80) - 0x80))
                pc += 2
                continue
            tgt = (mem.get(pc + 1, 0) | (mem.get(pc + 2, 0) << 8)) if n == 3 else None
            if op == 0x20 and tgt is not None:     # JSR
                best = max(best, local + 2 + depth(mem, tgt, stack | {entry}, memo))
            elif op == 0x4C:
                if tgt is not None:
                    work.append(tgt)
                break
            elif op in (0x60, 0x40, 0x6C, 0x00):
                break
            pc += n
    memo[entry] = best
    return best


def main():
    GAME = 6                    # measured by zpmap.py
    FLOOR = 0x100 - GAME        # $FA
    worst, rows = 0, []
    for path in sys.argv[1:]:
        mem, syms = load(path)
        for e, at in ENTRIES:
            if e not in syms:
                continue
            d = depth(mem, syms[e]) + 2        # +2 for the JSR that got here
            base = POKE_DEPTH if at == "poke" else 0
            rows.append((path.split("/")[-1], e, d, base, base + d))
            worst = max(worst, base + d)

    print("dmstack: the game's own deepest chain is %d bytes (floor $%02X)"
          % (GAME, FLOOR))
    print("dmstack:   file       entry     own  called-at  total")
    for f, e, d, base, tot in rows:
        print("dmstack:   %-10s %-8s %4d  %9d  %5d" % (f, e, d, base, tot))
    total = max(worst, GAME)
    print("dmstack: high-water %d bytes -- the deepest any single point in the "
          "frame reaches" % total)
    avail = 0x100 - 0xFA
    if total > avail:
        print("dmstack: FAIL -- %d bytes of stack against %d available "
              "($FA-$FF). It would run into $%02X and below: DMTMP, then the "
              "last byte of the sixth playfield stream. An overrun there does "
              "not crash, it corrupts the track, slowly, and only in a match."
              % (total, avail, 0xFA - (total - avail)))
        sys.exit(1)
    print("dmstack: PASS -- %d of %d bytes" % (total, avail))


if __name__ == '__main__':
    main()
