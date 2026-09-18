#!/usr/bin/env bash
# run_stall.sh -- M4: a stalled frame stalls the SIMULATION and not the PICTURE.
#
# The stall is the primitive the whole transport rests on: a console waits for
# a peer by drawing a frame with the game-logic chain skipped. Two claims pull
# in opposite directions and both have to hold:
#
#   * the simulation must stop -- cars, chase car and frame counter frozen;
#   * the picture must not -- the frame-length distribution unchanged, because
#     a console that stutters visibly whenever its peer is a tick behind is
#     showing the latency rather than absorbing it.
#
# It builds TWICE: once normally and once with DMSTALLT=1, which stalls every
# other tick with no network involved. Measuring the mechanism, not the
# transport.
set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)
FRAMES=${1:-${FRAME_COUNT_IN:-1800}}
MAME=${MAME:-$HOME/Workspace/mame}
SECS=$(( FRAMES / 60 + 8 ))

run() {  # run <out>
    ( cd "$MAME" && FRAME_COUNT=$FRAMES timeout $((SECS * 20 + 60)) \
        ./mame a2600 -skip_gameinfo -cartslot fujinet -cart "$HERE/build/dodgem.bin" \
        -autoboot_script "$HERE/emu/stall.lua" \
        -video none -sound none -nothrottle -seconds_to_run "$SECS" 2>/dev/null \
    ) | grep "^STALL" > "$HERE/build/$1"
}

echo "== normal build =="
./build.sh > /dev/null; run stall_off.txt; cat build/stall_off.txt
echo "== DMSTALLT=1 =="
DMSTALLT=1 ./build.sh > /dev/null; run stall_on.txt; cat build/stall_on.txt
./build.sh > /dev/null          # leave a normal image behind

pct() { grep -m1 "^STALL frames" "$1" | sed 's/.*(\([0-9.]*\)%).*/\1/'; }
lines() { grep -m1 "^STALL lines" "$1"; }

off=$(pct build/stall_off.txt); on=$(pct build/stall_on.txt)
echo
echo "stall: the simulation advanced on $off% of frames normally, $on% when stalling"

awk -v a="$off" -v b="$on" 'BEGIN { exit !(a > 95) }' || {
    echo "stall: FAIL -- the normal build only advanced on $off% of frames." \
         "Something is stalling that should not be." >&2; exit 1; }
awk -v a="$off" -v b="$on" 'BEGIN { exit !(b < a - 15) }' || {
    echo "stall: FAIL -- stalling every other tick changed advancement from" \
         "$off% to $on%. The gate is not gating." >&2; exit 1; }

lo=$(lines build/stall_off.txt); ln=$(lines build/stall_on.txt)
[ "$lo" = "$ln" ] || {
    echo "stall: FAIL -- the picture changed when the simulation stalled" >&2
    echo "  normal:  $lo" >&2
    echo "  stalling: $ln" >&2
    exit 1; }

echo "stall: PASS -- the simulation stalls, the picture does not"
echo "stall:        $lo"
