#!/usr/bin/env bash
# run_frames.sh -- every frame the same length, and the SAME length as stock.
#
#   test/run_frames.sh [frames]
#
# Two claims, and the second is the one the siblings make:
#   * every frame in the split build is the same length as every other, so
#     nothing the netcode does varies the picture;
#   * and that length is the one STOCK measures, so the port has not quietly
#     moved the raster.
#
# The number is LEARNED from stock and not written down here. Combat is 259
# lines because it has no overscan at all; Dodge 'Em is 262. A gate that
# asserts a number from a specification is asserting something about the
# specification.
#
# A MISSING REPORT IS A FAILURE, not a pass. emu/frames.lua arrived from a
# sibling ending in add_machine_stop_notifier, which never fires in this MAME:
# the harness measured everything correctly and printed nothing at all. A gate
# whose output is empty cannot fail, which is the shape Tennis's PORTING.md 3.2
# is about.
set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)
FRAMES=${1:-${FRAME_COUNT:-900}}
MAME=${MAME:-$HOME/Workspace/mame}
SECS=$(( FRAMES / 60 + 8 ))

[ -f build/dodgem.bin ] || { echo "run_frames: build/dodgem.bin missing" >&2; exit 1; }
cp -f rom/dodgem.bin build/stock.bin

run() {  # run <slot> <image> <out>
    ( cd "$MAME" && FRAME_COUNT=$FRAMES timeout $((SECS * 20 + 60)) \
        ./mame a2600 -skip_gameinfo -cartslot "$1" -cart "$HERE/build/$2" \
        -autoboot_script "$HERE/emu/frames.lua" \
        -video none -sound none -nothrottle -seconds_to_run "$SECS" 2>/dev/null \
    ) > "$HERE/build/$3"
}

mode_of() { grep -m1 "^FRAMES " "$1" | sed 's/.*mode \([0-9]*\) lines.*/\1/'; }
odd_of()  { grep -m1 "^FRAMES " "$1" | sed 's/.*, \([0-9]*\) not the mode/\1/'; }

echo "== stock =="; run a26_2k_4k stock.bin frames_stock.txt
grep -E "^LINES|^FRAMES " build/frames_stock.txt || true
echo "== split =="; run fujinet dodgem.bin frames_split.txt
grep -E "^LINES|^FRAMES |^BANK" build/frames_split.txt || true

for f in frames_stock frames_split; do
    grep -q "^FRAMES " "build/$f.txt" || {
        echo "frames: $f produced no report -- the harness measured nothing." \
             "That is a failure, not a pass." >&2; exit 1; }
done

sm=$(mode_of build/frames_stock.txt); so=$(odd_of build/frames_stock.txt)
dm=$(mode_of build/frames_split.txt); do_=$(odd_of build/frames_split.txt)

echo
[ "$so" = "0" ] || { echo "frames: FAIL -- stock itself has $so odd frames" >&2; exit 1; }
[ "$do_" = "0" ] || { echo "frames: FAIL -- the split build has $do_ frames that are not $dm lines" >&2; exit 1; }
[ "$sm" = "$dm" ] || { echo "frames: FAIL -- stock measures $sm lines, the split build $dm" >&2; exit 1; }
echo "frames: PASS -- $FRAMES frames, every one $dm lines, the same as stock"
