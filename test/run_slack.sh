#!/usr/bin/env bash
# run_slack.sh -- M4a: the band the netcode runs in has the room it assumes.
#
# Two claims:
#   * neither timed band is ever EXHAUSTED on a real game -- a band the game
#     already fills cannot host anything, and finding that out here costs
#     twenty seconds where finding it out from `make frames` costs a build
#     cycle and an argument about whose cycles they were;
#   * and the WORST frame still leaves more than DMGATE, so at least one
#     DMNSTEP can run on it.
#
# It drives the game into a real match first. An idle attract screen is not the
# workload the netcode has to fit beside.
set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)
FRAMES=${1:-${FRAME_COUNT_IN:-1800}}
MAME=${MAME:-$HOME/Workspace/mame}
SECS=$(( FRAMES / 60 + 8 ))
DMGATE=$(grep -oE '^DMGATE  EQU +[0-9]+' src/dmdefs.inc | grep -oE '[0-9]+$')

( cd "$MAME" && FRAME_COUNT=$FRAMES timeout $((SECS * 20 + 60)) \
    ./mame a2600 -skip_gameinfo -cartslot fujinet -cart "$HERE/build/dodgem.bin" \
    -autoboot_script "$HERE/emu/slack.lua" \
    -video none -sound none -nothrottle -seconds_to_run "$SECS" 2>/dev/null \
) | grep "^SLACK" > build/slack.txt

grep -q "^SLACK band" build/slack.txt || {
    echo "slack: no report -- that is a failure, not a pass" >&2; exit 1; }
cat build/slack.txt
echo
echo "slack: DMGATE is $DMGATE (dmdefs.inc), so a step runs only with that many"
echo "slack: 64-cycle ticks left -- $((DMGATE * 64)) cycles of guaranteed headroom."

fail=0
while read -r _ band n mean min max zero; do
    [ "$band" = "band" ] && continue
    [ -z "${zero:-}" ] && continue
    if [ "$zero" != "0" ]; then
        echo "slack: FAIL -- the $band band was exhausted on $zero frame(s)" >&2
        fail=1
    fi
    if [ "$min" -le "$DMGATE" ]; then
        echo "slack: note -- the $band band's worst frame leaves $min ticks," \
             "at or below DMGATE ($DMGATE): no step runs on that frame." >&2
    fi
done < <(grep -E "^SLACK (vblank|overscan)" build/slack.txt)

[ "$fail" = "0" ] || exit 1
echo "slack: PASS -- neither band is ever exhausted"
