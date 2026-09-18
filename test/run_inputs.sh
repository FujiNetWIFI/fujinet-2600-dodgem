#!/usr/bin/env bash
# run_inputs.sh -- M3: the game no longer reads a console port.
#
# Every read of SWCHA, SWCHB, INPT4 or INPT5 in a whole run must come from
# inside a DMMIX body, plus ONE deliberate exception: $F0F5's SWCHB read, which
# picks the black-and-white switch. B/W is a local preference here -- each
# player keeps their own -- so it is not on the wire and reading it live is
# correct.
#
# The allowed addresses are READ OUT OF THE LISTINGS, not written down: DMMIX
# moves whenever a bank is repacked, and a hand-copied address is a gate that
# passes on the wrong thing.
set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)
FRAMES=${1:-${FRAME_COUNT:-1800}}
MAME=${MAME:-$HOME/Workspace/mame}
SECS=$(( FRAMES / 60 + 8 ))

[ -f build/dodgem.bin ] || { echo "run_inputs: build/dodgem.bin missing" >&2; exit 1; }

( cd "$MAME" && FRAME_COUNT=$FRAMES timeout $((SECS * 20 + 60)) \
    ./mame a2600 -skip_gameinfo -cartslot fujinet -cart "$HERE/build/dodgem.bin" \
    -autoboot_script "$HERE/emu/inputs.lua" \
    -video none -sound none -nothrottle -seconds_to_run "$SECS" 2>/dev/null \
) | grep "^INPUTS" > build/inputs.txt

grep -q "^INPUTS frames=" build/inputs.txt || {
    echo "inputs: the harness produced no report -- that is a failure, not a pass" >&2
    exit 1; }
cat build/inputs.txt

# THE GATE MUST HAVE REACHED THE CODE IT IS JUDGING.
#
# Sixteen of the twenty-four read sites are turn-decision points behind
# `BIT $94 / BVC`, reached only in the variation where a human drives the chase
# car. Sitting in attract, this gate sees nine sites and passes -- and passed
# with a SWCHA patch deliberately removed, because the site it had un-patched
# was never executed. So the harness drives SELECT twice and RESET, and the
# state it reached is asserted here rather than hoped for.
state=$(grep -m1 "^INPUTSTATE" build/inputs.txt || true)
[ -n "$state" ] || { echo "inputs: no state line -- cannot tell what was reached" >&2; exit 1; }
echo "$state" | grep -qE "mode=[^ ]*\bC[0-9A-F]" || {
    echo "inputs: FAIL -- \$94 never reached the two-player variation (\$Cx)." \
         "The turn-point reads were not exercised, so a pass would mean" \
         "nothing. $state" >&2; exit 1; }
echo "$state" | grep -q "run=.*80" || {
    echo "inputs: FAIL -- \$95 bit 7 never set: the game never started." \
         " $state" >&2; exit 1; }

python3 - "$HERE" <<'PY'
import re, sys, glob
here = sys.argv[1]

# Where DMMIX is in each bank, and how long it is, from the assembler.
allowed = []
# The BANK listings only. build/dm_org.lst is the stock image rebuilt for
# verify-org; its addresses are $Fxxx and mean nothing in a banked window, and
# letting it widen the allowed set is how a gate stops being tight.
BANKS = [here + "/build/dm%s.lst" % b for b in ("g0", "g1", "g2", "g3", "boot")]
for lst in [p for p in BANKS if glob.glob(p)]:
    txt = open(lst, errors="replace").read()
    m = re.search(r'\bDMMIX :\s+([0-9A-F]{4})', txt)
    if not m:
        continue
    base = int(m.group(1), 16)
    allowed.append((base, base + 0x30, "DMMIX in " + lst.split("/")[-1]))

# The one deliberate live read: LF0F5, wherever it landed.
for lst in [p for p in BANKS if glob.glob(p)]:
    txt = open(lst, errors="replace").read()
    m = re.search(r'\bLF0F5 :\s+([0-9A-F]{4})', txt)
    if m:
        a = int(m.group(1), 16)
        allowed.append((a, a + 4, "LF0F5 live B/W read in " + lst.split("/")[-1]))

sites, bad = 0, []
for ln in open(here + "/build/inputs.txt"):
    m = re.match(r'^INPUTS\s+(\w+)@([0-9A-F]{4})\s+x(\d+)', ln)
    if not m:
        continue
    sites += 1
    pc = int(m.group(2), 16)
    if not any(lo <= pc <= hi for lo, hi, _ in allowed):
        bad.append("%s@$%04X x%s" % (m.group(1), pc, m.group(3)))

print()
print("inputs: %d distinct read sites; allowed regions:" % sites)
for lo, hi, why in allowed:
    print("   $%04X-$%04X  %s" % (lo, hi, why))
if sites == 0:
    sys.exit("inputs: FAIL -- no console-port reads at all. The game reads its "
             "controller every frame; zero reads means the harness is not "
             "watching, not that the patch is complete.")
if bad:
    for b in bad:
        print("   OUTSIDE: " + b)
    sys.exit("inputs: FAIL -- %d site(s) read a console port from outside the "
             "shim" % len(bad))
print("inputs: PASS -- every console-port read comes from the shim")
PY
