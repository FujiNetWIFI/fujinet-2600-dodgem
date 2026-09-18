#!/usr/bin/env bash
# run_dodgem.sh -- M1: measure what a FujiNet mailbox transaction costs.
#
# Brings up one isolated fujinet-pc, the echo server, and one MAME running
# build/dodgem.bin, then prints the frame cost of OPEN, WRITE, STATUS and READ
# and the implied lockstep tick rate.
#
#   test/run_dodgem.sh [seconds]
#
# The fujinet-pc is a COPY of the distribution, in build/rig/fn1, so the run
# cannot disturb a real one: nametest-style accidents in this family have
# rewritten the machine-wide username appkey before now. Its BoIP listener
# takes ONE client and the symptom of a second is a hang rather than an error,
# so everything this script starts, it kills first.

set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)

SECS=${1:-${SECS:-40}}
RELAY_PORT=${RELAY_PORT:-9603}
# NOT 9995. The 2600 cartridge model defaults there, and on this machine a
# long-running fujinet-pc has held 127.0.0.1:9995 since September. A rig that
# used the default would silently measure THAT instance -- ours would log
# "bind failed: Address already in use" in a file nobody reads, and the numbers
# would be of some other build's transport. The family's rule is that a rig
# kills its own instances; the corollary is that it must not be able to reach
# anyone else's.
BOIP_PORT=${BOIP_PORT:-19995}
FNPC_DIST=${FNPC_DIST:-$HOME/Workspace/fujinet-pc-rs232/build/dist}
RIG="$HERE/build/rig/fn1"

# Kill only OUR instances. The pattern must be anchored on this rig's own
# directory: a bare `pkill -f fujinet` on this machine would take out several
# long-running ones, and the family's rule is that a rig never types a pattern
# it would not want to type on an interactive shell.
cleanup() {
    pkill -f "mame a2600" 2>/dev/null || true
    pkill -f "$RIG/fujinet" 2>/dev/null || true
    # Belt and braces: anything whose cwd is this rig, whatever it calls itself.
    for pid in $(pgrep -x fujinet 2>/dev/null || true); do
        [ "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" = "$RIG" ] && kill "$pid" 2>/dev/null
    done
    [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null || true
    return 0
}
trap cleanup EXIT
cleanup
sleep 0.5

[ -f build/dodgem.bin ] || { echo "run_dodgem: build/dodgem.bin missing -- make dodgem" >&2; exit 1; }

# A fresh copy every run: a fujinet-pc that accumulated state across runs would
# make a measurement depend on what the last one did.
rm -rf "$RIG"
mkdir -p "$RIG"
cp -a "$FNPC_DIST"/. "$RIG"/
python3 - "$RIG/fnconfig.ini" "$BOIP_PORT" <<'PY'
import re, sys
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r"(\[BOIP\][^\[]*?\bport=)\d*", r"\g<1>" + port, s, flags=re.S)
s = re.sub(r"(\[BOIP\][^\[]*?\benabled=)\d*", r"\g<1>1", s, flags=re.S)
open(path, "w").write(s)
PY

echo "== relay on :$RELAY_PORT =="
setsid python3 server/dodgem_relay_server.py --port "$RELAY_PORT" \
    --host 127.0.0.1 --variation 3 --lobby-url "" \
    < /dev/null > build/relay.log 2>&1 &
RELAY_PID=$!
sleep 0.5

echo "== fujinet-pc (BoIP :$BOIP_PORT) =="
# Launched by ABSOLUTE path, on purpose. `cd "$RIG" && ./fujinet` puts the
# string "./fujinet" in the process's command line, and `pkill -f "$RIG/fujinet"`
# then matches nothing -- so every run leaks a fujinet that still holds the BoIP
# port, and the NEXT run measures whichever one happened to bind first. That is
# the same hazard the family documents as "a leftover fujinet-pc holds its port
# and every later launch silently no-ops", arriving through the cleanup pattern
# rather than through forgetting to clean up at all.
( cd "$RIG" && setsid "$RIG/fujinet" < /dev/null > "$HERE/build/fn1.log" 2>&1 & )
sleep 2

# Prove OUR instance owns the port before MAME connects to it. A bind failure
# here is the difference between measuring this transport and measuring
# whatever else happens to be listening.
if grep -q "bind failed" "$HERE/build/fn1.log"; then
    echo "run_dodgem: our fujinet-pc could not bind :$BOIP_PORT --" \
         "something else holds it. Aborting rather than measuring it." >&2
    grep -m2 "bind failed" "$HERE/build/fn1.log" >&2
    exit 1
fi
grep -m1 "BoIPChannel: listening" "$HERE/build/fn1.log" || true

echo "== MAME, ${SECS}s, throttled =="
# ABSOLUTE. MAME must be run from its own tree or -autoboot_script is silently
# ignored, so every relative path a harness opens resolves against MAME's cwd
# and not this one.
SECS="$SECS" FUJINET_TCP="127.0.0.1:$BOIP_PORT" \
    DMSYMS="$HERE/build/dmsyms.lua" ./run.sh dodgem sess \
    < /dev/null > build/dodgem.out 2>&1 || true
cat build/dodgem.out

echo
echo "== the relay saw =="
cat build/relay.log

# ONE console cannot pair -- it takes two -- so the most this proves is that
# the HELLO arrived and was accepted. That is exactly what it is for: it
# separates "the socket and the handshake work" from "two consoles agree",
# which is the rig's question and a much more expensive one to debug.
# The relay does not log the word HELLO; it logs the RESULT of one, which is
# the console's name and television standard. Grepping for the message name
# rather than for the evidence is how a gate ends up failing on a thing that
# worked -- this one did, for three iterations, while the console was opening
# a socket and being named correctly the whole time.
grep -qE "is [A-Z0-9]+ \((NTSC|PAL)\)" build/relay.log || {
    echo "session: FAIL -- the relay never named this console, so the HELLO" \
         "never arrived or was refused" >&2; exit 1; }
grep -q "connected" build/relay.log || {
    echo "session: FAIL -- the relay saw no connection" >&2; exit 1; }
echo "session: PASS -- socket opened, HELLO delivered, and the relay named it:"
sed -n 's/^[0-9:]* */  /p' build/relay.log | grep " is " 
