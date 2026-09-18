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
FRAMES=${1:-${FRAME_COUNT:-1500}}
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

echo "== stock ==" ; run a26_2k_4k stock.bin frames_stock.txt
grep -E "^LINES|^FRAMES " build/frames_stock.txt || true
echo "== split ==" ; run fujinet dodgem.bin frames_split.txt
grep -E "^LINES|^FRAMES |^BANK" build/frames_split.txt || true

for f in frames_stock frames_split; do
    grep -q "^LINES " "build/$f.txt" || {
        echo "frames: $f produced no report -- the harness measured nothing." \
             "That is a failure, not a pass." >&2; exit 1; }
done

# COMPARE THE WHOLE DISTRIBUTION, not the mode.
#
# Measured in attract this game runs a flat 262 lines and an equality test on
# the mode was enough. Driven into a real match it runs 261 and 262 mixed --
# because DODGE 'EM ITSELF varies, and stock varies identically. Asserting
# "every frame the same length" would have been asserting something about the
# attract screen.
#
# So the claim is the honest one: the split build's frame-length distribution
# is the same as stock's, line for line. That catches a frame the netcode
# lengthened AND a frame it shortened, without needing to know which lengths
# the game is entitled to.
ls=$(grep -m1 "^LINES " build/frames_stock.txt)
ld=$(grep -m1 "^LINES " build/frames_split.txt)
echo
if [ "$ls" != "$ld" ]; then
    echo "frames: FAIL -- the distributions differ" >&2
    echo "  stock: $ls" >&2
    echo "  split: $ld" >&2
    exit 1
fi
echo "frames: PASS -- $FRAMES frames, distribution identical to stock"
echo "frames:        $ld"
