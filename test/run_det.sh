#!/usr/bin/env bash
# run_det.sh -- does the split build play exactly like the 1980 cartridge?
#
#   test/run_det.sh [frames]
#
# Runs the stock dump and the split image through the same harness and requires
# the per-frame sim-state checksums to be identical -- AND to change, because a
# gate that only measures agreement will pass two machines that are agreeing
# about nothing (Combat 4.18).
#
# LONGER THAN IT FEELS IT NEEDS TO BE, on purpose. Video Olympics' PORTING.md
# 3.20 is the account: a ten-second gate is not a short thirty-second gate, it
# is a different gate, and the bug it found lived its whole life behind one
# that passed at ten. Everything this port has found so far arrived late --
# the pointer lows at frame 96, the pinned tables at 134, the crash
# animation's termination test at 292.
set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)
FRAMES=${1:-${DET_FRAMES:-3000}}
MAME=${MAME:-$HOME/Workspace/mame}

[ -f build/dodgem.bin ] || { echo "run_det: build/dodgem.bin missing -- make dodgem" >&2; exit 1; }
cp -f rom/dodgem.bin build/stock.bin

# seconds_to_run must outlast the frame count: 60 fps plus slack for the boot.
SECS=$(( FRAMES / 60 + 8 ))

run() {  # run <slot> <image> <split?> <out>
    ( cd "$MAME" && DET_SPLIT=$3 DET_FRAMES=$FRAMES timeout $((SECS * 20 + 60)) \
        ./mame a2600 -skip_gameinfo -cartslot "$1" -cart "$HERE/build/$2" \
        -autoboot_script "$HERE/emu/det.lua" \
        -video none -sound none -nothrottle -seconds_to_run "$SECS" 2>/dev/null \
    ) | grep "^DET" > "$HERE/build/$4"
}

echo "== stock, $FRAMES frames =="
run a26_2k_4k stock.bin "" det_stock.txt
tail -1 build/det_stock.txt

echo "== split, $FRAMES frames =="
run fujinet dodgem.bin 1 det_split.txt
tail -1 build/det_split.txt

echo
sd=$(grep -c "^DET " build/det_stock.txt)
dd=$(grep -c "^DET " build/det_split.txt)
[ "$sd" -ge "$FRAMES" ] || { echo "det: stock produced only $sd frames of $FRAMES" >&2; exit 1; }
[ "$dd" -ge "$FRAMES" ] || { echo "det: split produced only $dd frames of $FRAMES" >&2; exit 1; }

# The state must MOVE. Two builds that both sit still agree perfectly.
distinct=$(grep "^DETSUM" build/det_stock.txt | sed 's/.*distinct=//')
[ "$distinct" -gt $((FRAMES / 4)) ] || {
    echo "det: stock visited only $distinct distinct states in $FRAMES frames --" \
         "this gate is measuring a game that is not playing" >&2; exit 1; }

if diff -q <(grep "^DET " build/det_stock.txt) <(grep "^DET " build/det_split.txt) >/dev/null; then
    echo "det: PASS -- $FRAMES frames byte-identical, $distinct distinct states"
else
    n=$(diff <(grep "^DET " build/det_stock.txt) <(grep "^DET " build/det_split.txt) | grep -c '^<' || true)
    first=$(diff <(grep "^DET " build/det_stock.txt) <(grep "^DET " build/det_split.txt) | head -2 | tail -1 | awk '{print $3}')
    echo "det: FAIL -- $n frames differ, first at frame $first" >&2
    exit 1
fi
