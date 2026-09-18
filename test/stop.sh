#!/usr/bin/env bash
# stop.sh -- tear down whatever test/run_play.sh brought up, and nothing else.
#
# The sibling's version was `pkill -x mame`, which is every MAME on the
# machine: running it while a rig was measuring took the rig down too, and the
# rig reported two consoles that never reached the snapshot tick -- which reads
# exactly like a desync. So this kills by identity, not by program name:
#
#   MAME        only the two that were handed build/dodgem{1,2}.bin
#   the relay   only the pid run_play.sh recorded, or one on run_play's port
#   fujinet-pc  only those whose working directory is under build/play/
#
# A bare `pkill -f fujinet` on this machine would take out several long-running
# ones that have nothing to do with this project at all.
cd "$(dirname "$0")/.."
HERE=$(pwd)
RELAY_PORT=${RELAY_PORT:-9603}

# TERM, then wait, then KILL. MAME does not always act on a TERM while it owns
# an SDL window -- two runs' worth of windows survived one and sat there for
# twenty minutes, and the next launch simply added two more on top. Escalating
# is the difference between a teardown and a suggestion.
ours() {
    for pid in $(pgrep -x mame 2>/dev/null || true); do
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -qE "build/dodgem[12]\.bin" && echo "$pid"
    done
    return 0
}
for pid in $(ours); do kill "$pid" 2>/dev/null || true; done
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(ours)" ] && break
    sleep 0.3
done
for pid in $(ours); do kill -9 "$pid" 2>/dev/null || true; done

if [ -f build/play/relay.pid ]; then
    kill "$(cat build/play/relay.pid)" 2>/dev/null || true
    rm -f build/play/relay.pid
fi
pkill -f "dodgem_relay_server.py.*--port $RELAY_PORT" 2>/dev/null || true

for pid in $(pgrep -x fujinet 2>/dev/null || true); do
    case "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" in
        "$HERE"/build/play/*) kill "$pid" 2>/dev/null ;;
    esac
done
echo "stopped"
