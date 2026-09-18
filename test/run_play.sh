#!/usr/bin/env bash
# run_play.sh -- two consoles you can actually play, side by side.
#
#   test/run_play.sh      two MAME windows, open-ended
#   test/stop.sh          tear it all down
#
# The same infrastructure as test/run_rig.sh -- two isolated fujinet-pc copies
# on their own BoIP ports, one relay -- but windowed, open-ended, and with no
# -seconds_to_run and no Lua tap. The rig proves it; this is for playing it.
#
# IT DELIBERATELY DOES NOT SHARE A SINGLE DIRECTORY OR PORT WITH THE RIG.
# run_rig.sh's cleanup kills every fujinet-pc whose working directory is under
# build/rig/fn*, and it is careful NOT to kill an emulator that is not its own
# -- which would have been a courtesy extended to the FujiNets and not to the
# consoles they serve, had this script put its two under the same prefix. So
# play owns build/play/fn{1,2} and BoIP 19997/19998; the rig owns build/rig
# and 19995/19996; neither teardown can reach into the other.
#
# The one thing they DO contend for is the relay port, because there is only
# one Dodge 'Em relay port. That collision is guarded on both sides and is
# loud: whichever starts second says so and exits.

set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)

RELAY_PORT=${RELAY_PORT:-9603}
BOIP1=${BOIP1:-19997}
BOIP2=${BOIP2:-19998}
FNPC_DIST=${FNPC_DIST:-$HOME/Workspace/fujinet-pc-rs232/build/dist}
MAME=${MAME:-$HOME/Workspace/mame}

# WITHOUT A DISPLAY run.sh exports SDL_VIDEODRIVER=dummy, because that is what
# every headless gate needs. Here it would open two windows nobody can see and
# report success -- so this is the one caller that must refuse it.
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    echo "run_play: no DISPLAY -- this target opens two windows to play in." >&2
    echo "run_play: the headless gates are 'make rig' and 'make rig-play'." >&2
    exit 1
fi

"$HERE/test/stop.sh" 2>/dev/null || true
sleep 0.5
mkdir -p build/play

# Two ROMs, because the two consoles must introduce themselves by different
# names: the relay refuses a duplicate by renaming it.
echo "== building two client ROMs =="
for n in 1 2; do
    PLAYER="PLAYER$n" ENDPOINT="N:TCP://127.0.0.1:$RELAY_PORT/" DMRSYT=0 \
        ./build.sh dodgem > "build/play/build$n.log" 2>&1
    cp build/dodgem.bin "build/dodgem$n.bin"
done

for n in 1 2; do
    port=$([ "$n" = 1 ] && echo "$BOIP1" || echo "$BOIP2")
    play="$HERE/build/play/fn$n"
    rm -rf "$play"; mkdir -p "$play"; cp -a "$FNPC_DIST"/. "$play"/
    python3 - "$play/fnconfig.ini" "$port" <<'PY'
import re, sys
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r"(\[BOIP\][^\[]*?\bport=)\d*", r"\g<1>" + port, s, flags=re.S)
s = re.sub(r"(\[BOIP\][^\[]*?\benabled=)\d*", r"\g<1>1", s, flags=re.S)
open(path, "w").write(s)
PY
    # Absolute path, so test/stop.sh can find it again: `cd dir && ./fujinet`
    # puts "./fujinet" in the command line and every pattern misses it.
    ( cd "$play" && setsid "$play/fujinet" < /dev/null \
        > "$HERE/build/play/fn$n.log" 2>&1 & )
done
sleep 2
for n in 1 2; do
    if grep -q "bind failed" "build/play/fn$n.log"; then
        echo "run_play: fujinet-pc $n could not bind its BoIP port -- something" \
             "else holds it. Aborting rather than talking to it." >&2
        grep -m1 "bind failed" "build/play/fn$n.log" >&2
        exit 1
    fi
done
echo "== two fujinet-pc on :$BOIP1 and :$BOIP2 =="

# VARIATION 3 IS THE WHOLE POINT. Dodge 'Em's game 3 is the two-player
# variation -- mode 11 in $94's top two bits -- and it is the only one the ROM
# will play over the network: the other variations put the chase car under the
# computer's control, which over a relay is two consoles simulating the same
# opponent separately and hoping.
setsid python3 server/dodgem_relay_server.py --host 127.0.0.1 \
    --port "$RELAY_PORT" --delay 2 --variation "${VARIATION:-3}" \
    --lobby-url "" \
    < /dev/null > build/play/relay.log 2>&1 &
RELAY_PID=$!
echo "$RELAY_PID" > build/play/relay.pid
sleep 1
if ! kill -0 "$RELAY_PID" 2>/dev/null; then
    echo "run_play: the relay could not take 127.0.0.1:$RELAY_PORT." >&2
    tail -3 build/play/relay.log >&2
    echo "run_play: a rig is probably up -- test/stop.sh, or set RELAY_PORT." >&2
    exit 1
fi
echo "== relay on :$RELAY_PORT  (tail -f build/play/relay.log) =="

# THROUGH run.sh, NOT A SECOND COPY OF THE MAME COMMAND LINE. The sibling port
# spelled the arguments out again here and quietly lost a controller flag in
# the process. One place describes how this ROM is run, and everything else
# goes through it.
launch() {   # launch <n> <boip-port>
    local n=$1 port=$2
    ( setsid env FUJINET_TCP="127.0.0.1:$port" MAME="$MAME" \
        "$HERE/run.sh" "dodgem$n" \
        < /dev/null > "$HERE/build/play/play$n.log" 2>&1 & )
}

launch 1 "$BOIP1"
sleep 2                     # let console 1 connect first, so it is the host
launch 2 "$BOIP2"

cat <<MSG

== two consoles up ==

  window 1 is PLAYER1, the host  -- its stick drives SWCHA's HIGH nibble
  window 2 is PLAYER2, the guest -- its stick drives the LOW nibble

  THE ARROW KEYS steer and LEFT CTRL is the button, in whichever window has
  focus. Click in a window first so MAME takes the keyboard; press the MAME UI
  key (Scroll Lock by default) to give it back.

  BOTH OF YOU ARE BUSY AT ALL TIMES, which is what makes this one worth
  playing over a wire. One of you drives the dot-collecting car through the
  maze; the other drives the CHASE car, hunting them. When a round ends the
  roles swap -- the game's own \$98 bit 7 decides who is dodging, and the
  netcode does not touch it, so the swap comes out of the 1980 logic exactly
  as it always did.

  CONSOLE 1 WILL WAIT ABOUT A SECOND for console 2 with a rolling picture.
  That is the session polling with the frame loop stopped, it is bounded on
  purpose, and it is written up in PORTING.md 13.1. It settles as soon as the
  pair is made.

  RESET and SELECT (F3 and F2) work from EITHER console: the two are ANDed on
  the wire, so either player may press them and both consoles see the same
  byte on the same tick.

  SELECT IS ABSORBED INSIDE A MATCH. The relay starts the pair on game 3 and
  the ROM pins mode 11 for the duration -- a press cannot walk the pair into a
  variation where one side is the computer.

  THE COLOUR / B-W SWITCH STAYS LOCAL, and is the one switch that does. Each
  of you keeps your own setting; it selects nothing, so it desyncs nothing.

  tail -f build/play/relay.log   what the relay sees
  test/stop.sh                   tear it down
MSG
