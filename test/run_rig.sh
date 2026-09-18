#!/usr/bin/env bash
# run_rig.sh -- two consoles, two FujiNets, one relay, one match.
#
#   test/run_rig.sh [seconds]
#
# The shape is the Intellivision family's: isolated copies of fujinet-pc so a
# run cannot disturb a real one, everything this script starts it kills first,
# and an inline verdict block rather than a human reading a log.
#
# Two things about this machine cost an afternoon each and are guarded here:
#
#   * A long-running fujinet-pc has held 127.0.0.1:9995 since September, and
#     the 2600 cartridge model connects there by DEFAULT. A rig on the default
#     port silently measures somebody else's FujiNet; ours logs "bind failed"
#     into a file nobody reads. So the rig uses its own ports and ABORTS if it
#     cannot have them.
#   * `cd "$RIG" && ./fujinet` puts "./fujinet" in the process's command line,
#     and `pkill -f "$RIG/fujinet"` then matches nothing. Every run leaked one,
#     and the next run measured the leak. Launch by absolute path.

set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)

SECS=${1:-${SECS:-40}}
RELAY_PORT=${RELAY_PORT:-9603}
BOIP1=${BOIP1:-19995}
BOIP2=${BOIP2:-19996}
FNPC_DIST=${FNPC_DIST:-$HOME/Workspace/fujinet-pc-rs232/build/dist}

cleanup() {
    # Only OUR emulators: a `make play` session may be up on other ports and
    # killing it would be rude as well as wrong.
    for pid in $(pgrep -x mame 2>/dev/null || true); do
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -q "build/rig/${RIGDIR:-fn}dodgem" && kill "$pid" 2>/dev/null
    done
    for n in 1 2; do
        pkill -f "$HERE/build/rig/${RIGDIR:-fn}$n/fujinet" 2>/dev/null || true
    done
    for pid in $(pgrep -x fujinet 2>/dev/null || true); do
        case "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" in
            "$HERE"/build/rig/"${RIGDIR:-fn}"*) kill "$pid" 2>/dev/null ;;
        esac
    done
    [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null || true
    return 0
}
trap cleanup EXIT
cleanup
sleep 0.5

mkdir -p build/rig

# Two ROMs, because the two consoles must introduce themselves by different
# names: the relay refuses a duplicate by renaming it, and a rig that relied on
# that would be testing the rename.
for n in 1 2; do
    # DMRSYT goes to console 1 ONLY. A checksum both consoles corrupt
    # identically is a checksum they still agree about.
    PLAYER="PLAYER$n" ENDPOINT="N:TCP://127.0.0.1:$RELAY_PORT/" \
        DMRSYT="$([ "$n" = 1 ] && echo "${DMRSYT:-0}" || echo 0)" \
        ./build.sh dodgem > "build/rig/build$n.log" 2>&1
    cp build/dodgem.bin "build/rig/${RIGDIR:-fn}dodgem$n.bin"
done
echo "== built two client ROMs =="

for n in 1 2; do
    port=$([ "$n" = 1 ] && echo "$BOIP1" || echo "$BOIP2")
    rig="$HERE/build/rig/${RIGDIR:-fn}$n"
    rm -rf "$rig"
    mkdir -p "$rig"
    cp -a "$FNPC_DIST"/. "$rig"/
    python3 - "$rig/fnconfig.ini" "$port" <<'PY'
import re, sys
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r"(\[BOIP\][^\[]*?\bport=)\d*", r"\g<1>" + port, s, flags=re.S)
s = re.sub(r"(\[BOIP\][^\[]*?\benabled=)\d*", r"\g<1>1", s, flags=re.S)
open(path, "w").write(s)
PY
    ( cd "$rig" && setsid "$rig/fujinet" < /dev/null > "$HERE/build/rig/fn$n.log" 2>&1 & )
done
sleep 2
for n in 1 2; do
    if grep -q "bind failed" "build/rig/fn$n.log"; then
        echo "run_rig: fujinet-pc $n could not bind its BoIP port -- something" \
             "else holds it. Aborting rather than measuring it." >&2
        grep -m1 "bind failed" "build/rig/fn$n.log" >&2
        exit 1
    fi
done
echo "== two fujinet-pc on :$BOIP1 and :$BOIP2 =="

setsid python3 server/dodgem_relay_server.py --host 127.0.0.1 \
    --port "$RELAY_PORT" --delay 2 --variation "${VARIATION:-3}" \
    --lobby-url "" \
    < /dev/null > build/rig/relay.log 2>&1 &
RELAY_PID=$!
sleep 1
# THE SAME GUARD THE BoIP PORTS GET, FOR THE SAME REASON. A relay left running
# by `make play` still owns 9603; this one dies with "Address already in use"
# into a log nobody reads, the two consoles pair against the OTHER relay, and
# every verdict below is measured somewhere else. It cost a whole ladder run.
if ! kill -0 "$RELAY_PID" 2>/dev/null; then
    echo "run_rig: the relay could not take 127.0.0.1:$RELAY_PORT." >&2
    tail -3 build/rig/relay.log >&2
    echo "run_rig: something else holds it -- test/stop.sh, or set RELAY_PORT." >&2
    exit 1
fi
echo "== relay on :$RELAY_PORT =="

# DMSYMS IS ABSOLUTE. MAME must be run from its own tree or -autoboot_script is
# silently ignored, so every relative path a harness opens resolves against
# MAME's directory and not this one. The symptom is a Lua error that kills the
# tap, which reads as a console that never reached the snapshot -- which reads
# as a desync.
#
# And it is set HERE rather than in the middle of the continued command below:
# a comment after a `\` ends the continuation, the environment assignments
# become a command of their own, and the script exits without running either
# console. Which also reads as a desync.
for n in 1 2; do
    port=$([ "$n" = 1 ] && echo "$BOIP1" || echo "$BOIP2")
    SNAPTICK="${SNAPTICK:-150}" RIG_HOLD="${RIG_HOLD:-}" \
    PLAY_WINDOW="${PLAY_WINDOW:-}" \
    PLAY_INJECT="$([ "$n" = 1 ] && echo "${PLAY_INJECT:-}")" \
    SECS="$SECS" FUJINET_TCP="127.0.0.1:$port" \
        DMSYMS="$HERE/build/dmsyms.lua" \
        ./run.sh "rig/${RIGDIR:-fn}dodgem$n" "${RIG_LUA:-rig}" \
            < /dev/null > "build/rig/c$n.out" 2>&1 &
    sleep 1
done
wait_secs=$((SECS + 20))
for _ in $(seq "$wait_secs"); do
    pgrep -f "build/rig/${RIGDIR:-fn}dodgem" > /dev/null || break
    sleep 1
done
sleep 1

echo
echo "== console 1 =="; tail -7 build/rig/c1.out
echo "== console 2 =="; tail -7 build/rig/c2.out
echo "== relay =="; grep -v "CRC MISMATCH" build/rig/relay.log
echo "   $(grep -c "CRC MISMATCH" build/rig/relay.log || true) CRC MISMATCH lines"

# emu/play.lua's verdict is a different question, so it gets a different block:
# not "did these two agree" -- the relay answers that -- but WHICH CELL WENT
# FIRST. The state dump is megabytes, so only the diagnosis is printed.
if [ -n "${DMRSYT:-}" ] && [ "${DMRSYT:-0}" != 0 ]; then
    # THE REPAIR GATE ASKS THE OPPOSITE QUESTION of every other one: console 1
    # was built to corrupt its OWN checksum for eight ticks, so mismatches are
    # the point and silence would mean the injection missed. What has to be
    # true is that they STOPPED, and that the console noticed.
    echo
    n=$(grep -c "CRC MISMATCH" build/rig/relay.log || true)
    echo "== the relay saw $n CRC MISMATCH line(s) =="
    grep -m3 "CRC MISMATCH" build/rig/relay.log || true
    python3 tools/playdiff.py build/rig/c1.out build/rig/c2.out || true
    echo
    if [ "$n" = 0 ]; then
        echo "  FAIL the relay never saw the injected disagreement -- the" \
             "corruption did not reach the wire"
        echo "REPAIR FAIL"; exit 1
    fi
    echo "  ok   the relay saw the injected disagreement ($n line(s))"

    # DID THEY STOP? Measured in TICKS, not in log lines.
    #
    # The first version compared the last mismatch's position in the file
    # against the file's length, and raced the relay's own logging: the verdict
    # runs when the consoles exit and the relay is still writing, so the last
    # mismatch WAS the last line and the gate reported "nothing repaired" on a
    # run that had recovered forty seconds earlier.
    #
    # The tick a mismatch names does not move once written, and the highest
    # tick the consoles reached is in their own output. A window of mismatches
    # well below the end of the match is the claim being made.
    hi=$(grep -o "CRC MISMATCH tick [0-9]*" build/rig/relay.log \
         | grep -o "[0-9]*$" | sort -n | tail -1)
    lo=$(grep -o "CRC MISMATCH tick [0-9]*" build/rig/relay.log \
         | grep -o "[0-9]*$" | sort -n | head -1)
    end=$(grep -oh "ticks=[0-9]*" build/rig/c1.out | grep -o "[0-9]*" | tail -1)
    echo "  ..  mismatches span ticks $lo-$hi; the match ran ${end:-?} ticks"
    if [ -z "${end:-}" ] || [ "$end" -le "$hi" ]; then
        echo "  FAIL the mismatches ran to the end of the match -- nothing repaired"
        echo "REPAIR FAIL"; exit 1
    fi
    echo "  ok   the mismatches STOPPED, and the match ran on for" \
         "$((end - hi)) more ticks"
    echo "REPAIR PASS"; exit 0
fi

if [ "${RIG_LUA:-rig}" = "play" ] && [ -n "${PLAY_INJECT:-}" ]; then
    # The repair gate asks the OPPOSITE question: one console was deliberately
    # corrupted, so mismatches are the point and silence would mean the
    # injection missed. What has to be true is that they STOPPED.
    echo
    echo "== injection =="; grep -h "^INJECT" build/rig/c1.out || true
    python3 tools/playdiff.py build/rig/c1.out build/rig/c2.out --repair
    rc=$?
    echo
    if [ "$rc" = 0 ] && grep -q "CRC MISMATCH" build/rig/relay.log; then
        echo "REPAIR PASS"; exit 0
    fi
    [ "$rc" = 0 ] || echo "  FAIL the two consoles never came back together"
    grep -q "CRC MISMATCH" build/rig/relay.log \
        || echo "  FAIL the relay never saw the injected desync at all"
    echo "REPAIR FAIL"; exit 1
fi

# THE TWO CONSOLES MUST HOLD DIFFERENT ROLES.
#
# Not a nicety: the relay names one host and one guest, and the mixer puts the
# host's stick in SWCHA's high nibble on BOTH machines. If both believe they
# are the host they both put their OWN stick there -- and every checksum still
# agrees, because the error is symmetric. It passed for a whole afternoon.
# Only one of them can be right about this, which is exactly what makes it
# worth asserting.
if grep -qh "^PLAY \|^SNAP " build/rig/c1.out build/rig/c2.out 2>/dev/null; then
    r1=$(grep -ohm1 "ent=\$[0-9A-F][0-9A-F]" build/rig/c1.out | head -1)
    r2=$(grep -ohm1 "ent=\$[0-9A-F][0-9A-F]" build/rig/c2.out | head -1)
    if [ -n "$r1" ] && [ -n "$r2" ]; then
        b1=$(( 0x${r1#ent=$} & 2 )); b2=$(( 0x${r2#ent=$} & 2 ))
        if [ "$b1" = "$b2" ]; then
            echo "  FAIL both consoles hold the same role ($r1 $r2) -- one of" \
                 "them should be the guest"
        else
            echo "  ok   the two consoles hold DIFFERENT roles ($r1 $r2)"
        fi
    fi
fi

# THE SYNTHETIC SWCHB, IN A MATCH -- do the shadows MEAN what the game thinks?
#
# `make inputs` proves every console-port read comes from the shim. It proves
# nothing about the VALUES the shim hands back, and that is a separate claim
# with its own failure: the wire byte carries SELECT at bit 5 and RESET at bit
# 4, SWCHB carries them at bits 1 and 0, and the mixer stored them straight
# across. Both port bits read zero for ever -- active low -- so from the moment
# a match began the game saw RESET and SELECT held down, and no press by either
# player could reach it. Both consoles computed the same wrong byte, so every
# gate that measures agreement passed. PORTING.md 15.
if [ "${RIG_LUA:-rig}" = "switch" ]; then
    echo
    rc=0
    for n in 1 2; do
        echo "== console $n =="
        grep -E "^SWCHB|^  (ok|FAIL|--)" "build/rig/c$n.out" | sed 's/^/  /'
        grep -q "^SWITCH PASS" "build/rig/c$n.out" || rc=1
        # A MISSING VERDICT IS A FAILURE, NOT A PASS.
        grep -qE "^SWITCH (PASS|FAIL)" "build/rig/c$n.out" \
            || { echo "  FAIL console $n never reported"; rc=1; }
    done
    [ "$rc" = 0 ] && { echo "SWITCH PASS"; exit 0; }
    echo "SWITCH FAIL"; exit 1
fi

# THE RASTER, IN A MATCH -- the gate whose absence let a visibly broken picture
# ship past nineteen green ones.
#
# `make frames` runs ONE console with no relay. The session falls back, DME_NET
# stays clear, and DMWAIT returns on its second instruction: the gate that
# exists to prove the netcode does not move the raster was measuring a build in
# which the netcode never ran. In a match every fourth frame was 358 lines
# against stock's 261 -- a quarter of all frames, on both consoles -- and the
# only thing that ever reported it was a person looking at the screen.
#
# So the claim here is the same one `make frames` makes, against the workload
# it was always supposed to make it against: both consoles, in a match, every
# frame the length stock measures.
if [ "${RIG_LUA:-rig}" = "frames" ]; then
    echo
    stock=build/frames_stock.txt
    if [ ! -f "$stock" ]; then
        echo "  FAIL no $stock -- run 'make frames' first, so the line count"
        echo "       being asserted is one STOCK measured and not one written"
        echo "       down here"
        echo "FRAMES-MATCH FAIL"; exit 1
    fi
    smode=$(grep -m1 "^FRAMES " "$stock" | sed -n 's/.*mode \([0-9]*\) lines.*/\1/p')
    echo "  stock mode: $smode lines"
    rc=0
    for n in 1 2; do
        # A MISSING REPORT IS A FAILURE, NOT A PASS (PORTING.md 9.2).
        if ! grep -q "^FRAMES " "build/rig/c$n.out"; then
            echo "  FAIL console $n never reported at all"; rc=1; continue
        fi
        line=$(grep -m1 "^LINES " "build/rig/c$n.out")
        mode=$(grep -m1 "^FRAMES " "build/rig/c$n.out" | sed -n 's/.*mode \([0-9]*\) lines.*/\1/p')
        off=$(grep -m1 "^FRAMES " "build/rig/c$n.out" | sed -n 's/.*, \([0-9]*\) not the mode.*/\1/p')
        echo "  console $n: $line"
        if [ "$mode" != "$smode" ]; then
            echo "    FAIL mode is $mode lines, stock measures $smode"; rc=1
        fi
        if [ "${off:-0}" -gt 0 ] && grep -q "^BAD FRAME" "build/rig/c$n.out"; then
            echo "    FAIL frames off the mode, after the boot window:"
            grep -m3 "^BAD FRAME" "build/rig/c$n.out" | sed 's/^/      /'
            rc=1
        fi
    done
    # ...and it has to have been a MATCH. A console that never paired draws
    # perfectly steady frames and would pass this on nothing at all.
    # NOT `^match:`. THE RELAY TIMESTAMPS EVERY LINE -- "11:53:04 match: ..."
    # -- so an anchored pattern matches nothing, and this gate failed on its
    # own regex while the two consoles were paired and playing. PORTING.md 10.4
    # is the same mistake one section earlier: a gate that greps for evidence
    # the log does not carry is a gate that reports on itself.
    if ! grep -q " match: " build/rig/relay.log; then
        echo "  FAIL the relay never paired the two -- this measured two"
        echo "       consoles playing alone, which is what make frames does"
        rc=1
    fi
    [ "$rc" = 0 ] && { echo "FRAMES-MATCH PASS"; exit 0; }
    echo "FRAMES-MATCH FAIL"; exit 1
fi

if [ "${RIG_LUA:-rig}" = "play" ]; then
    echo
    python3 tools/playdiff.py build/rig/c1.out build/rig/c2.out
    rc=$?
    echo
    if [ "$rc" = 0 ] && ! grep -q "CRC MISMATCH" build/rig/relay.log; then
        echo "PLAY PASS"; exit 0
    fi
    echo "PLAY FAIL"; exit 1
fi

# The interception proof, IN A MATCH. Locally `make inputs` shows every read
# coming from DMLOC0; here the claim is the other half and it is the one that
# matters: in a match every read must come from DMCAP, and DMLOC0 must not run
# at all. A console still reading its own port during a match is reading an
# input the peer will never see.
if [ "${RIG_LUA:-rig}" = "inputs" ]; then
    echo
    python3 - build/rig/c1.out build/rig/c2.out build/dmkern.lst <<'PY'
import re, sys

# THE BOUNDS COME FROM THE ASSEMBLER'S OWN LISTING, never from a literal. A
# hardcoded address that means DMCAP in one build means the middle of it in the
# next, and the gate would go on passing.
syms, intab = {}, False
for line in open(sys.argv[3], errors="replace"):
    if "Symbol Table" in line:
        intab = True
        continue
    if not intab:
        continue
    for part in line.split("|"):
        m = re.match(r"^\s*\*?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([0-9A-F]{1,8})\b",
                     part.strip())
        if m:
            try:
                syms[m.group(1).upper()] = int(m.group(2), 16)
            except ValueError:
                pass

need = ("DMLOC0", "DMCAP", "DMSTALLN", "DMMIX", "DMPHI")
missing = [n for n in need if n not in syms]
if missing:
    print("  FAIL the listing has no %s" % ", ".join(missing))
    print("INPUTS FAIL")
    sys.exit(1)
lo, hi = syms["DMCAP"], syms["DMSTALLN"]
l0, l1 = syms["DMLOC0"], syms["DMCAP"]
# DMMIX READS SWCHB ONCE A TICK ON PURPOSE, and it is not a miss. Black and
# white stays LOCAL -- it reaches only the six colour cells and the attract
# masks, and no colour cell reaches physics or the checksum -- so each player
# sees their own setting, and the only way to honour that is to read the
# switch here rather than take it off the wire.
m0, m1 = syms["DMMIX"], syms["DMPHI"]
print("  DMCAP $%04X-$%04X, DMMIX $%04X-$%04X, DMLOC0 $%04X-$%04X"
      % (lo, hi - 1, m0, m1 - 1, l0, l1 - 1))

fails = []
for n, path in ((1, sys.argv[1]), (2, sys.argv[2])):
    out = open(path, errors="replace").read()
    sites = re.findall(r"^\s+(\w+) @ pc~\$([0-9A-F]{4})\s+x(\d+)", out, re.M)
    print("  console %d: %d site(s)" % (n, len(sites)))
    inloc = 0
    for name, pc, cnt in sites:
        a = int(pc, 16)
        # The PC read inside a tap has already moved on, so a read at X is
        # reported a couple of bytes past it. Widen the window rather than
        # chase the exact instruction: what is being asked is WHICH ROUTINE.
        where = ("DMCAP" if lo <= a <= hi + 4
                 else "DMMIX (B&W, local by design)" if m0 <= a <= m1 + 4
                 else "DMLOC0" if l0 <= a <= l1 + 4 else "elsewhere")
        if where == "DMLOC0":
            inloc += int(cnt)
        print("    %-6s pc~$%s  x%-6s %s" % (name, pc, cnt, where))
    def want(cond, what):
        print(("  ok   " if cond else "  FAIL ") + what)
        if not cond:
            fails.append(what)
    want(len(sites) > 0, "console %d reads its ports at all" % n)
    want(all(lo <= int(pc, 16) <= hi + 4 or m0 <= int(pc, 16) <= m1 + 4
             for _, pc, _ in sites),
         "console %d reads every port from DMCAP or DMMIX's B&W" % n)
    want(inloc == 0,
         "console %d never runs DMLOC0 in a match" % n)

print("INPUTS PASS" if not fails else "INPUTS FAIL")
sys.exit(1 if fails else 0)
PY
    exit $?
fi

python3 - build/rig/c1.out build/rig/c2.out build/rig/relay.log <<'PY'
import re, sys
c1, c2, relay = (open(p, errors="replace").read() for p in sys.argv[1:4])
fails = []

def want(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)

want("match:" in relay, "the relay paired the two consoles")
want("CRC MISMATCH" not in relay, "the two consoles never disagreed")

# The two snapshots are taken at the SAME simulated tick on both consoles, so
# they have to be identical byte for byte -- including the game variation, which
# is what proves SELECT reached both machines and advanced them together.
#
# SNAP is the SIMULATION only. The raw SWCHB port and the peer's ring slot moved
# to the LOCAL line, which is reported and never compared: with SELECT held on
# one console those two bytes differ BECAUSE the press is working, and comparing
# them asserted that both players had their hands in the same place.
sa = re.search(r"^SNAP .*$", c1, re.M)
sb = re.search(r"^SNAP .*$", c2, re.M)
want(sa is not None and sb is not None, "both consoles snapshotted the same tick")
if sa and sb:
    want(sa.group(0) == sb.group(0),
         "the two consoles agree byte for byte at the snapshot tick")
    ga = re.search(r": \w+ \w+ (\w+)", sa.group(0))
    gb = re.search(r": \w+ \w+ (\w+)", sb.group(0))
    want(ga and gb and ga.group(1) == gb.group(1),
         "the two consoles are on the SAME game variation")
    want(ga is not None and ga.group(1) != "24",
         "SELECT changed the variation away from the one START set")
for n, out in ((1, c1), (2, c2)):
    m = re.search(r"RIG tick=(\d+) err=\$([0-9A-F]{2}) state=(\d+)", out)
    want(m is not None, "console %d reported its state" % n)
    if m:
        tick, err = int(m.group(1)), int(m.group(2), 16)
        want(tick > 50, "console %d ran %d ticks" % (n, tick))
        want(err & 0x0F == 0, "console %d has no transport error ($%02X)" % (n, err))
print()
print("RIG FAIL" if fails else "RIG PASS")
sys.exit(1 if fails else 0)
PY
