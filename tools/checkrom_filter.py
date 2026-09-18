#!/usr/bin/env python3
"""checkrom_filter.py -- run the firmware's checkrom.py and judge its findings.

The upstream tool is authoritative and is not forked. But it walks every bank
LINEARLY looking for banned opcodes, and a linear walk loses sync the moment it
enters a data table -- and then carries the misalignment into the code that
follows it. Its own comment accepts that for the RMW check, which is gated on
the operand landing in the write-only page; the indirect-store check is gated on
nothing, so any $91 or $81 byte the walk happens to land on fails the build.

Combat filtered by DECLARED DATA REGION, which was enough for it: both of its
findings were inside tables. That is not enough here. Tennis's sim clock lives
at $81 and its sprite pointers at $90-$9B, so `LDA $81`, `INC $81`, `AND $81`
and `STA $0091,Y` put those byte values all over the CODE -- eight of the nine
in the image are operand bytes inside instructions, and a region filter would
drop one of them and fail the build on the other eight.

So the filter is an INSTRUCTION-BOUNDARY MAP, and the assembler already has one.
Every emitting line of a bank listing contributes exactly one boundary, at its
first address -- unless its mnemonic is DB or DW, in which case it contributes
none. Every other byte in the image is an operand or data, and a banned opcode
cannot be at one.

A finding is fatal iff its address is a boundary AND the byte there really is
what upstream said it was. Everything else is reported and dropped, with the
reason. This is mechanically complete, it covers the injected netcode for free
because that is in the same listings, and it needs no declared-data list at all.

It also corrects the reported address. checkrom.py labels every bank but bank 0
as though it were based at $1800, which is right for the fixed half and wrong
for the banked ones -- they are all mapped at $1000.

Usage: checkrom_filter.py <checkrom.py> <image.bin>
"""

import os
import re
import subprocess
import sys

BANK_SZ = 0x800

# slot in the image -> (listing, the address that slot is mapped at)
SLOTS = [("build/tnboot.lst", 0x1000),
         ("build/tngame.lst", 0x1000),
         ("build/tnkern.lst", 0x1000),
         ("build/tntail.lst", 0x1800)]

FINDING = re.compile(
    r"^checkrom: (?P<img>\S+): bank (?P<bank>\d+) \$(?P<addr>[0-9A-Fa-f]{4}): (?P<what>.*)$")

# `(1)  312/1027 : E0 DA        CPX  #TNZPLO`  -- depth prefix optional
EMIT = re.compile(r"^\s*(?:\(\d+\)\s*)?\d+/([0-9A-F]{4})\s*:\s*"
                  r"((?:[0-9A-Fa-f]{2} )+)\s*(\S+)")

DATA_DIRECTIVES = {"DB", "DW", "DD", "DS", "BYT", "ADR"}

# the opcodes upstream bans, and what it calls them
BANNED = {0x91: "STA (zp),Y", 0x81: "STA (zp,X)"}
RMW = {0x06, 0x16, 0x0E, 0x1E, 0x46, 0x56, 0x4E, 0x5E,
       0x26, 0x36, 0x2E, 0x3E, 0x66, 0x76, 0x6E, 0x7E,
       0xC6, 0xD6, 0xCE, 0xDE, 0xE6, 0xF6, 0xEE, 0xFE}


def boundaries(path):
    """The set of addresses at which an INSTRUCTION starts in one listing."""
    out = set()
    if not os.path.exists(path):
        return None
    for line in open(path, errors="replace"):
        m = EMIT.match(line)
        if not m:
            continue
        if m.group(3).upper() in DATA_DIRECTIVES:
            continue                    # data contributes no boundaries
        out.add(int(m.group(1), 16))
    return out


def main():
    tool, image = sys.argv[1], sys.argv[2]
    img = open(image, "rb").read()
    r = subprocess.run([sys.executable, tool, image], capture_output=True, text=True)
    sys.stdout.write(r.stdout)

    maps = []
    for lst, base in SLOTS:
        b = boundaries(lst)
        if b is None:
            print("checkrom_filter: %s is missing; cannot judge findings" % lst,
                  file=sys.stderr)
            return 1
        maps.append((b, base))

    fatal, dropped = [], []
    for line in r.stderr.splitlines():
        m = FINDING.match(line)
        if not m:
            if line.strip():
                fatal.append(line)
            continue
        slot = int(m.group("bank"))
        if slot >= len(maps):
            fatal.append(line + "   [slot %d is outside the image]" % slot)
            continue
        bounds, base = maps[slot]
        off_in_bank = int(m.group("addr"), 16) & (BANK_SZ - 1)
        addr = base + off_in_bank
        byte = img[slot * BANK_SZ + off_in_bank]
        what = m.group("what").split(" -- ")[0]

        if addr not in bounds:
            dropped.append("$%04X (slot %d, byte $%02X): %s -- not an "
                           "instruction boundary" % (addr, slot, byte, what))
        elif byte not in BANNED and byte not in RMW:
            dropped.append("$%04X (slot %d, byte $%02X): %s -- the byte there "
                           "is not the opcode reported" % (addr, slot, byte, what))
        else:
            fatal.append("checkrom: slot %d $%04X: %s (byte $%02X)"
                         % (slot, addr, what, byte))

    for d in dropped:
        print("checkrom: dropped: " + d)
    for f in fatal:
        print(f, file=sys.stderr)
    if fatal:
        print("checkrom_filter: %d finding(s) stand" % len(fatal), file=sys.stderr)
        return 1
    print("checkrom_filter: %s passes (%d finding(s) dropped with reason)"
          % (image, len(dropped)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
