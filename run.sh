#!/usr/bin/env bash
# run.sh -- run a Tennis client ROM in a FujiNet-patched MAME.
#
#   ./run.sh [rom] [lua-script]
#
# With a script it runs headless and exits; without one it opens a window.
# `rom` is a basename in build/ and defaults to dodgem.
#
# The MAME tree must have had fn-2600/pico/atari-2600/emu/apply.sh run against
# it, and for anything that touches the network a fujinet-pc must be listening.
#
# Four environment facts this wraps, each of which costs time to rediscover:
#   - MAME must run FROM ITS OWN TREE or -autoboot_script is silently ignored.
#   - SDL_VIDEODRIVER=dummy is required wherever there is no DISPLAY, because
#     SDL comes up before the video backend is chosen.
#   - fujinet-pc's BoIP listener takes ONE client, so a MAME left running
#     starves the next run and the symptom is a hang, not an error.
#   - THROTTLED IS NOT A PERFORMANCE CHOICE for anything measuring latency:
#     unthrottled, a bounded poll loop expires in wall-microseconds and the
#     measurement reports the emulator's speed rather than the transport's.

set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)

ROM=${1:-dodgem}
SCRIPT=${2:-}
MAME=${MAME:-$HOME/Workspace/mame}

# ONLY A PREVIOUS RUN OF THIS ROM. This used to be `pkill -f "mame a2600"`,
# which is every 2600 MAME on the machine -- so starting a forensic rig tore
# down the two windows somebody was playing in, on different ports, for no
# reason. The listener this needs to free is the one the SAME image holds.
pkill -f "build/$ROM.bin" 2>/dev/null || true
# MAME'S DEFAULT CONTROLLER IS THE RIGHT ONE HERE, and the sibling port is why
# that is worth a note rather than silence. Video Olympics is a paddle game and
# had to pass `-joyport1 pad -joyport2 pad`, because MAME defaults both slots to
# `joy` -- and with the wrong device in the slot the game still runs and every
# gate that compares two builds against each other still passes, since both
# sides are equally wrong. Tennis is a joystick game, so the default is correct
# and nothing is passed. The `-cartslot fujinet` is the part that is not a
# default: it is the FujiNet cartridge device emu/apply.sh grafts into MAME.
args=(a2600 -window -skip_gameinfo -cartslot "${SLOT:-fujinet}"
      -cart "$HERE/build/$ROM.bin"
      -snapshot_directory "$HERE/build/snap")

if [ -n "$SCRIPT" ]; then
    LUA="$HERE/emu/$SCRIPT.lua"
    [ -f "$LUA" ] || LUA="${FN2600:-$HOME/Workspace/fn-2600/pico/atari-2600}/emu/$SCRIPT.lua"
    args+=(-autoboot_script "$LUA" -video none -sound none
           -seconds_to_run "${SECS:-20}")
    [ -n "${FAST:-}" ] && args+=(-nothrottle)
fi

[ -n "${DISPLAY:-}" ] || export SDL_VIDEODRIVER=dummy
export FUJINET_TCP="${FUJINET_TCP:-127.0.0.1:9995}"
export A2600_EMU="$HERE/emu"
export A2600_FWEMU="${FN2600:-$HOME/Workspace/fn-2600/pico/atari-2600}/emu"

cd "$MAME"
exec ./mame "${args[@]}"
