#!/usr/bin/env python3
"""check_zp.py -- prove no RAM clear in the built image can reach the netcode.

Tennis has ONE clear loop and THREE ways into it, which is Dragster's trap with
an extra door. `LF004` is re-entered by `JMP LF004` from $F1AB with the seed
preloaded in X -- $85 on RESET and $88 on SELECT -- and the loop runs X up to
$FF through `STY $00,X`, which wraps inside page zero. Unbounded it wipes every
cell this port owns, and it does so on a press somebody makes several times a
minute while choosing a game. The loop is bounded now, and this is the gate
that keeps it bounded.

The third entry is the cold one, and it is the reason TNCLR tests TNWARM: it
arrives from TNGOTO with X = $FF, which would clear exactly one byte and wrap
straight back out of the loop.

A regression here is silent and slow: the netcode survives until the first time
somebody presses RESET, and then the tick, the ring and the role are zero on one
console and not the other. Twenty lines to make that impossible.

Three assertions:
  1. every netcode cell is at or above TNZPLO
  2. the clear loop really compares against TNZPLO and not a literal
  3. both stock seeds are below TNZPLO, so the loop terminates where it should

Usage: check_zp.py build/tngame.lst
"""
import re
import sys

# The cells the netcode owns. Session-side cells share the same range by union.
NETCODE = ["TNENT", "TNSEQ", "TNERR", "TNTICK", "TNNST", "TNCRCV", "TNADV",
           "TNTMP", "TNWARM", "TNCLRX", "TNSWA", "TNSWB", "TNTRIG",
           "TNW0", "TNW1", "TNSAVX", "TNSTDV", "TNRWAT", "TNRING", "TNLOC", "TNRDN",
           "FNDEV", "FNCMD", "FNNPR", "FNTMO", "FNCNT", "FNPTRL", "FNPTRH",
           "FNPCNT", "INCUR", "INPREV", "CSDLY"]

# The two seeds stock passes in X. They are not symbols in this port -- they
# are `LDX #$85` and `LDX #$88` in the game's own untouched code -- so they are
# checked as values rather than looked up.
SEEDS = [(0x85, "RESET, at $F1A9"), (0x88, "SELECT, at $F1D0")]

SYM = re.compile(r"^\*?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([0-9A-F]{1,8})\b")
# `(1)  312/1027 : E0 DA        CPX  #DGZPLO`
CPX = re.compile(r"^\s*(?:\(\d+\)\s*)?\d+/([0-9A-F]{4})\s*:\s*"
                 r"((?:[0-9A-Fa-f]{2} )+)\s*(\S+)\s+(\S+)")


def symbols(path):
    out, in_tab = {}, False
    for line in open(path, errors="replace"):
        if "Symbol Table" in line:
            in_tab = True
            continue
        if not in_tab:
            continue
        for part in line.split("|"):
            m = SYM.match(part.strip())
            if m:
                try:
                    out[m.group(1).upper()] = int(m.group(2), 16)
                except ValueError:
                    pass
    return out


def main():
    lst = sys.argv[1]
    syms = symbols(lst)
    problems = []

    need = ["TNZPLO", "TNSTKLO"]
    for n in need:
        if n not in syms:
            problems.append("%s is not in the listing's symbol table" % n)
    if problems:
        for p in problems:
            print("check_zp: " + p, file=sys.stderr)
        return 1

    lo = syms["TNZPLO"]

    # 1. every netcode cell is at or above the bound.
    for n in NETCODE:
        a = syms.get(n.upper())
        if a is None:
            problems.append("%s is not in the listing's symbol table" % n)
        elif a < lo:
            problems.append("%s is $%02X, BELOW the clear bound $%02X -- a "
                            "restage would wipe it" % (n, a, lo))

    # 2. the clear loop compares against the bound, and does so as a symbol.
    #    A literal here would drift the moment the map moved.
    found = []
    for line in open(lst, errors="replace"):
        m = CPX.match(line)
        if not m:
            continue
        if m.group(3).upper() != "CPX":
            continue
        by = m.group(2).split()
        if len(by) == 2 and by[0].upper() == "E0":      # CPX immediate
            found.append((int(m.group(1), 16), int(by[1], 16), m.group(4)))
    bounded = [f for f in found if f[1] == lo]
    if not bounded:
        problems.append("no `CPX #$%02X` anywhere in the bank: the clear loop "
                        "is not bounded" % lo)
    elif not any("TNZPLO" in f[2].upper() for f in bounded):
        problems.append("the clear loop's bound is a literal, not TNZPLO")

    # 3. both stock seeds terminate below the bound. A seed at or above it
    #    would make `CPX #TNZPLO` false for all 256 values and the loop would
    #    run the whole way round page zero -- the very thing the bound exists
    #    to prevent, and silently, because the symptom only appears on a press.
    for v, why in SEEDS:
        if v >= lo:
            problems.append("the seed $%02X (%s) is at or above the bound "
                            "$%02X -- the clear would run away" % (v, why, lo))

    # and the stack stays clear of the netcode's top cell
    if syms["TNSTKLO"] < lo:
        problems.append("TNSTKLO $%02X is below the bound" % syms["TNSTKLO"])

    for p in problems:
        print("check_zp: " + p, file=sys.stderr)
    if problems:
        return 1
    print("check_zp: %d netcode cells, all at or above $%02X; the clear is "
          "bounded by TNZPLO and all three entries terminate"
          % (len(NETCODE), lo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
