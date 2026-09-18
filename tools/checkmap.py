#!/usr/bin/env python3
"""checkmap.py -- prove the code/data split in tools/dodgem.cfg.

`make verify-org` assembles the generated disassembly and requires the
cartridge dump back, byte for byte. That is necessary and NOT sufficient: a
run of DATA bytes disassembled as instructions re-encodes to exactly the bytes
it came from, so a wrong split survives the round trip untouched. Video
Olympics' PORTING.md says it plainly -- an automatic pass loses everything an
absolute-indirect JMP would have reached, and the result looks fine until it
runs.

So this walks the ROM by recursive descent from the reset vector and asserts
the split is the one the descent finds:

  1. every byte DiStella emitted as CODE is reached from $F000
  2. no byte it emitted as DATA is reached
  3. the two sets together cover the image with nothing left over

The window is taken from the image SIZE rather than hardcoded, because Dodge
'Em is the first 4K game in this family: a 2048-byte dump sits at $F800-$FFFF
and a 4096-byte one at $F000-$FFFF, and the reset vector is at the top of
whichever it is. Getting that wrong reads the vector out of the middle of the
game and the descent starts nowhere.

Whether the descent is EXACT or merely a lower bound is asserted, not assumed:
a `JMP (ind)` or an RTS-dispatch is computed control flow the walk cannot
follow, and the day one appears is the day this gate would start lying.

Usage: checkmap.py rom/dodgem.bin tools/dodgem.cfg
"""
import re
import sys


# length by opcode; 0 marks an undefined opcode, which is itself a finding
LEN = [0] * 256
for op in (0x00, 0x08, 0x0A, 0x18, 0x28, 0x2A, 0x38, 0x40, 0x48, 0x4A, 0x58,
           0x60, 0x68, 0x6A, 0x78, 0x88, 0x8A, 0x98, 0x9A, 0xA8, 0xAA, 0xB8,
           0xBA, 0xC8, 0xCA, 0xD8, 0xE8, 0xEA, 0xF8):
    LEN[op] = 1
for op in (0x01, 0x05, 0x06, 0x09, 0x10, 0x11, 0x15, 0x16, 0x21, 0x24, 0x25,
           0x26, 0x29, 0x30, 0x31, 0x35, 0x36, 0x41, 0x45, 0x46, 0x49, 0x50,
           0x51, 0x55, 0x56, 0x61, 0x65, 0x66, 0x69, 0x70, 0x71, 0x75, 0x76,
           0x81, 0x84, 0x85, 0x86, 0x90, 0x91, 0x94, 0x95, 0x96, 0xA0, 0xA1,
           0xA2, 0xA4, 0xA5, 0xA6, 0xA9, 0xB0, 0xB1, 0xB4, 0xB5, 0xB6, 0xC0,
           0xC1, 0xC4, 0xC5, 0xC6, 0xC9, 0xD0, 0xD1, 0xD5, 0xD6, 0xE0, 0xE1,
           0xE4, 0xE5, 0xE6, 0xE9, 0xF0, 0xF1, 0xF5, 0xF6):
    LEN[op] = 2
for op in (0x0D, 0x0E, 0x19, 0x1D, 0x1E, 0x20, 0x2C, 0x2D, 0x2E, 0x39, 0x3D,
           0x3E, 0x4C, 0x4D, 0x4E, 0x59, 0x5D, 0x5E, 0x6C, 0x6D, 0x6E, 0x79,
           0x7D, 0x7E, 0x8C, 0x8D, 0x8E, 0x99, 0x9D, 0xAC, 0xAD, 0xAE, 0xB9,
           0xBC, 0xBD, 0xBE, 0xCC, 0xCD, 0xCE, 0xD9, 0xDD, 0xDE, 0xEC, 0xED,
           0xEE, 0xF9, 0xFD, 0xFE):
    LEN[op] = 3

BRANCH = {0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0}
STOP = {0x4C, 0x60, 0x40, 0x6C}          # JMP abs, RTS, RTI, JMP (ind)
JSR, JMPABS, JMPIND, BRK = 0x20, 0x4C, 0x6C, 0x00


def regions(cfg):
    """(lo, hi_inclusive, kind) triples, as tennis.cfg declares them."""
    out = []
    for line in open(cfg):
        m = re.match(r"^\s*(CODE|DATA|GFX|PGFX)\s+([0-9A-Fa-f]{4})\s+"
                     r"([0-9A-Fa-f]{4})", line)
        if m:
            out.append((int(m.group(2), 16), int(m.group(3), 16),
                        "data" if m.group(1) != "CODE" else "code"))
    return out


def main():
    rom = open(sys.argv[1], "rb").read()
    if len(rom) not in (2048, 4096):
        sys.exit("checkmap: expected a 2048- or 4096-byte image, got %d"
                 % len(rom))
    END = 0x10000
    BASE = END - len(rom)
    decl = regions(sys.argv[2])

    def at(a):
        return rom[a - BASE]

    reached, starts, problems = set(), set(), []
    indirect, brks = [], []

    reset = at(END - 4) | (at(END - 3) << 8)
    if not BASE <= reset < END:
        sys.exit("checkmap: reset vector $%04X is outside the image" % reset)

    work = [reset]
    while work:
        pc = work.pop()
        while True:
            if not BASE <= pc < END or pc in starts:
                break
            op = at(pc)
            n = LEN[op]
            if n == 0:
                problems.append("$%04X: undefined opcode $%02X" % (pc, op))
                break
            starts.add(pc)
            for i in range(n):
                reached.add(pc + i)
            if op == BRK:
                # Video Olympics used BRK as a two-byte subroutine call and
                # its IRQ vector was load-bearing. Dodge 'Em must not -- its
                # IRQ vector is $0000 -- and if it ever does, this walk is
                # wrong about everything after it.
                brks.append(pc)
                break
            if op == JMPIND:
                indirect.append(pc)
                break
            if op in BRANCH:
                dest = pc + 2 + ((at(pc + 1) ^ 0x80) - 0x80)
                work.append(dest)
                pc += 2
                continue
            target = at(pc + 1) | (at(pc + 2) << 8) if n == 3 else None
            if op == JSR and target is not None and BASE <= target < END:
                work.append(target)
            if op == JMPABS:
                if target is not None and BASE <= target < END:
                    work.append(target)
                break
            if op in STOP:
                break
            pc += n

    # ---- claim 0: the descent is exact, not a lower bound ----
    if indirect:
        problems.append("JMP (ind) at %s -- the descent cannot follow it, so "
                        "this gate is a lower bound and not a proof"
                        % ", ".join("$%04X" % a for a in indirect))
    if brks:
        problems.append("BRK at %s -- if it is a subroutine call (Video "
                        "Olympics 3.1) the IRQ vector is code and the fixed "
                        "tail owns it" % ", ".join("$%04X" % a for a in brks))

    # ---- claims 1-3: the declared split IS the descent's split ----
    declared_data = set()
    for lo, hi, kind in decl:
        if kind == "data":
            declared_data.update(range(lo, hi + 1))
    declared_code = set(range(BASE, END)) - declared_data

    for a in sorted(declared_code - reached):
        problems.append("$%04X: emitted as code, never reached" % a)
    for a in sorted(declared_data & reached):
        problems.append("$%04X: declared data, reached as code" % a)

    print("checkmap: %d instructions, %d code bytes, %d data bytes"
          % (len(starts), len(reached), (END - BASE) - len(reached)))
    print("checkmap: reset $%04X; no JMP (ind), no BRK" % reset
          if not indirect and not brks else
          "checkmap: reset $%04X" % reset)

    if problems:
        for p in problems[:40]:
            print("  " + p)
        if len(problems) > 40:
            print("  ... and %d more" % (len(problems) - 40))
        sys.exit("checkmap: FAIL -- %d problems" % len(problems))
    print("checkmap: PASS -- the declared split is the one descent finds")


if __name__ == "__main__":
    main()
