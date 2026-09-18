#!/usr/bin/env bash
#
# build.sh -- networked Dodge 'Em for the Atari 2600, over a FujiNet cartridge.
#
# The client image is (N+1) x 2048 bytes: N banks served at $1000-$17FF, then
# the 2K fixed half. MAME's vcs_cart_slot_device::call_load() accepts only
# 4096 / 8192 / 16384 / 32768, so N is 1, 3, 7 or 15 and nothing between.
#
# Dodge 'Em is the first TRUE 4K game in this family -- Combat, Video Olympics,
# Dragster and Tennis were all 2K and fit one bank. 3426 bytes of code and 466
# of data do not, so the game alone takes three banks and the image is 16384.
# That is not a tight fit dressed up: it is the choice that lets the bank
# boundaries be picked where the code actually divides (see tools/mkbanks.py)
# rather than where the arithmetic forces them.
#
# Usage:
#   ./build.sh disasm       DiStella over the dump, steered by tools/dodgem.cfg
#   ./build.sh verify-org   the disassembly IS the cartridge, byte for byte
#   ./build.sh zp           the zero-page census (M0c)
#   ./build.sh probe        the flat 4K latency probe
#   ./build.sh              the client
#
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

FUJI_FIRMWARE=${FUJI_FIRMWARE:-$HOME/Workspace/fn-2600}
VCS=${VCS:-$FUJI_FIRMWARE/pico/atari-2600}
DISTELLA=${DISTELLA:-$HOME/Workspace/distella/distella}

# ---------------- the television standard ----------------
#
# A 2600 cannot detect its own television standard at runtime: the ROM
# generates the video timing and there is nothing to read. So the choice is a
# build-time one, and SECAM is refused rather than silently mis-served.
#
# The reason here is Combat's and Video Olympics', not Tennis's: a SECAM TIA
# renders eight colours chosen by the hue nibble and ignores the luminance
# bits, and Dodge 'Em draws BOTH cars from one colour table at $FF2C, EOR'd
# against $A6 -- the two cars differ by luminance. On a SECAM set both players
# would be driving identical sprites round the same track.
tvstd=${TVSTD:-ntsc}
case "$tvstd" in
    ntsc) tvstd=0 ;;
    pal)  tvstd=1 ;;
    secam)
        cat >&2 <<'EOF'
build.sh: TVSTD=secam is refused.

A SECAM TIA picks its eight colours from the hue nibble alone and ignores
luminance. Dodge 'Em draws both cars out of the colour table at $FF2C EOR'd
with $A6, and they differ by LUMINANCE -- so on a SECAM television the two
players would see identical cars and could not tell which one they were
driving. That is not a cosmetic difference in a game about not being caught.

The relay refuses a SECAM client for the same reason; the two refusals have to
agree, or a player gets paired into a match they cannot see.
EOF
        exit 1 ;;
    *) echo "build.sh: TVSTD must be ntsc or pal (got '$tvstd')" >&2; exit 1 ;;
esac

# ---------------- the toolchain ----------------
AS=$(command -v asl    || true); [ -x "${AS:-}"    ] || AS=$HOME/asl/asl
P2BIN=$(command -v p2bin || true); [ -x "${P2BIN:-}" ] || P2BIN=$HOME/asl/p2bin
for t in "$AS" "$P2BIN"; do
    [ -x "$t" ] || { echo "build.sh: no Macroassembler AS at $t" >&2; exit 1; }
done

mkdir -p build

# ---------------- the equates agree with the cartridge ----------------
#
# FIRST, before anything is assembled. src/fujinet.inc is a hand-mirror of
# fuji_mailbox.h, and the failure mode when it drifts is not a build error: an
# early sibling had the control page at $1C00 where the spec says $1D00, so
# every register write went to a page that decodes nothing, every read fell
# through to the served window and returned $00, and the client came up, drew
# a screen, and simply never armed the mailbox.
checkdefs() {
    python3 "$VCS/tools/checkdefs.py" \
        "$VCS/firmware/include/fuji_mailbox.h" src/fujinet.inc \
        --extra FB_POKE=FN_BLIT_POKE,FB_TCELL=FN_BLIT_TCELL,\
FB_RAW=FN_BLIT_RAW,FB_TEXT=FN_BLIT_TEXT,FB_PATH=FN_BLIT_PATH,\
FNBGEN=FN_B_BLITGEN
}

# p2bin, and the overlap check.
#
# AS does not complain when two ORGs put code on top of each other -- it
# records both and moves on. p2bin is where it surfaces, as "overlapping
# memory allocation!", and it is a WARNING there too: the later record simply
# wins and part of a bank is silently gone.
#
# In a port whose banks are PACKED that is not a cosmetic complaint, it is the
# failure mode of the whole scheme, so it is fatal here. It has already caught
# one real instance: the region cursor computed from stock instruction sizes,
# against patches that change size.
p2bin() {  # p2bin <in.p> <out.bin> <args...>
    local out
    out=$("$P2BIN" "$@" 2>&1)
    [ -n "$out" ] && echo "$out"
    if echo "$out" | grep -q "overlapping"; then
        echo "build.sh: $1 has overlapping regions -- part of it was silently" \
             "overwritten. Refusing to build." >&2
        exit 1
    fi
    return 0
}

# An image carrying "FUJI" at $1F10 promises it is a FujiNet client, so the
# mailbox stays live after it boots. Without it the cartridge treats the image
# as an ordinary game and the mailbox goes dead the moment it starts.
stampclaim() {
    local f=$1 size
    size=$(stat -c%s "$f")
    printf 'FUJI' | dd of="$f" bs=1 \
        seek=$((size - 0x800 + 0x0710)) conv=notrunc status=none
    echo "$f: $size bytes"
}

# AS writes its .p and .lst next to the source, so assemble from the source's
# own directory and collect the artefacts into build/.
assemble() {  # assemble <basename> [srcdir]
    local b=$1 d=${2:-src} out
    # AS reports an overlap as a WARNING and carries on, letting the later
    # write win. In a packed bank that is not a cosmetic complaint: it means
    # two regions were placed on top of each other and some of one of them is
    # simply gone. Treat it as fatal.
    ( cd "$d" && "$AS" -q -L -i . -i "$HERE/src" -i "$HERE/build" "$b.asm" )
    if [ "$d" != "build" ]; then
        mv "$d/$b.p" "build/$b.p"
        mv -f "$d/$b.lst" "build/$b.lst" 2>/dev/null || true
    fi
}

# The disassembly is GENERATED, never committed and never hand-edited. DiStella
# writes its progress to STDOUT, in front of the source, so it is filtered here
# rather than left to break the assembler with four lines it cannot parse.
disasm() {
    [ -x "$DISTELLA" ] || {
        echo "build.sh: no DiStella at $DISTELLA (set DISTELLA=...)" >&2
        exit 1
    }
    "$DISTELLA" -paf -ctools/dodgem.cfg rom/dodgem.bin 2>/dev/null \
        | sed '/^Using .*config file$/d; /^PASS [123]$/d' > rom/dodgem.asm
    echo "disasm: $(wc -l < rom/dodgem.asm) lines"
}

if [ "${1:-}" = "disasm" ]; then
    disasm
    exit 0
fi

# ---------------- M0b: the conversion gate ----------------
#
# TWO claims, and only the second is a round trip.
#
#   checkmap.py  the declared code/data split is the one a recursive descent
#                from the reset vector actually finds. A run of data bytes
#                disassembled as instructions re-encodes to exactly the bytes
#                it came from, so the cmp below cannot see a wrong split at
#                all -- it is the failure mode Video Olympics' PORTING.md
#                warns about, and this is the gate for it.
#   cmp          and then it really is the cartridge, byte for byte.
if [ "${1:-}" = "verify-org" ]; then
    [ -f rom/dodgem.asm ] || disasm
    python3 tools/checkmap.py rom/dodgem.bin tools/dodgem.cfg
    python3 tools/dasm2as.py rom/dodgem.asm > build/dm_org.asm
    assemble dm_org build
    p2bin build/dm_org.p build/dm_org.bin -r '$F000-$FFFF' -l 255 -q
    rm -f build/dm_org.p
    cmp build/dm_org.bin rom/dodgem.bin
    echo "verify-org: byte-identical ($(stat -c%s build/dm_org.bin) bytes)"
    exit 0
fi

# ---------------- M0c: the zero-page census ----------------
#
# The gate that decides this port. Dodge 'Em uses all 128 bytes of RAM, so
# where the netcode's state lives is not a detail to settle later -- it is the
# first question, and zpmap.py answers it with liveness rather than a touch
# scan. See PORTING.md.
if [ "${1:-}" = "defs" ]; then
    checkdefs
    exit 0
fi

if [ "${1:-}" = "zp" ]; then
    # It needs the DUMP and the ASSEMBLER'S LISTING: the dump for the opcodes,
    # the listing for the code/data split, because a linear walk through a data
    # table is misaligned garbage that invents references. build/dm_org.lst is
    # verify-org's output, so make that first if it is not there.
    [ -f build/dm_org.lst ] || "$0" verify-org
    python3 tools/zpmap.py rom/dodgem.bin build/dm_org.lst
    echo
    python3 tools/check_zp.py rom/dodgem.bin build/dm_org.lst src/dmdefs.inc
    exit 0
fi

# ---------------- the bank carve ----------------
if [ "${1:-}" = "banks" ]; then
    [ -f build/dm_org.lst ] || "$0" verify-org
    [ -f build/dmregions.py ] || "$0" phase > /dev/null
    python3 tools/dmbanks.py build/dm_org.lst build/dm_org.asm build
    # Assemble each bank and report the seams it cannot resolve. Those are
    # the cross-bank references, and they are EXPECTED until the trampolines
    # land -- the point of packing the regions is that the assembler names
    # them. The count is what has to go to zero, not the build.
    seams=0
    for b in g0 g1 g2 g3; do
        n=$( ( cd build && "$AS" -q -i . -i "$HERE/src" -i . "dm$b.asm" 2>&1 ) \
             | grep -c 'symbol undefined' || true )
        printf '  dm%s: %d unresolved cross-bank reference(s)\n' "$b" "$n"
        seams=$((seams + n))
    done
    echo "dmbanks: $seams reference seam(s) + 2 fall-through seam(s) to trampoline"
    exit 0
fi

# ---------------- M1: the transaction latency probe ----------------
#
# A flat 4K image: one bank of code and the fixed half, no banking -- there is
# nothing here big enough to need it. It measures how many video frames one
# mailbox transaction costs, and every latency number in this port hangs off
# that figure.
#
# The endpoint is regenerated every run so a stale value cannot survive an
# environment change, and that is the whole reason it is a build-time string
# rather than something read from an appkey: the probe has to run before there
# is a lobby.
if [ "${1:-}" = "probe" ]; then
    {
        echo "; generated by build.sh -- do not edit"
        printf 'UENDPT: DB      "%s"\n' \
            "${ENDPOINT:-N:TCP://127.0.0.1:9605/}"
        echo "        DB      0"
    } > build/endpoint.inc

    assemble probe
    python3 tools/checkbanks.py build/probe.lst $((0x1800)) probe
    p2bin build/probe.p build/probe.bin -r '$1000-$1FFF' -l 255 -q
    rm -f build/probe.p
    stampclaim build/probe.bin
    python3 tools/checkrom_filter.py "$VCS/tools/checkrom.py" build/probe.bin \
        "build/probe.lst@0x1000"
    # The harness taps cells by address; publish them rather than letting a
    # Lua file carry a hand-copied number that nothing checks.
    python3 tools/mksyms.py build/probe.lst build/probesyms.lua \
        PSTEP PROUND DMFCNT DMERR
    exit 0
fi

# ---------------- the patch map is anchored where it says ----------------
#
# Before anything builds on the map: every declared site is an instruction
# boundary carrying the declared bytes. The anchor is an address and its
# opcodes, not a line number of the generated disassembly -- see the header of
# tools/patches.py for why, given 51 sites against Tennis's handful.
if [ "${1:-}" = "anchors" ]; then
    [ -f rom/dodgem.asm ] || disasm
    [ -f build/dm_org.lst ] || "$0" verify-org
    python3 tools/check_anchors.py rom/dodgem.bin build/dm_org.lst rom/dodgem.asm
    exit 0
fi

# ---------------- the bank map, computed ----------------
if [ "${1:-}" = "phase" ]; then
    [ -f build/dm_org.lst ] || "$0" verify-org
    python3 tools/dmphase.py rom/dodgem.bin build/dm_org.lst
    exit 0
fi

# ---------------- the client ----------------
#
# (N+1) x 2048: N banks at $1000-$17FF then the 2K fixed half. MAME's
# vcs_cart_slot_device::call_load() accepts only 4096/8192/16384/32768, so N is
# 1, 3, 7 or 15 and nothing between -- this is 7 banks and 16384 bytes.
#
# Banks 5 and 6 are spare and are filled rather than omitted: the image size is
# what the mapper reads, so a short image is a different cartridge.
BANKS="dmg0 dmg1 dmg2 dmg3 dmboot"

# Build-time switches, regenerated every run so a stale value cannot survive an
# environment change. They must be EQUates and not IFDEFs: AS resolves IF in
# its FIRST PASS, and a condition naming a symbol defined further down the file
# is not a build error -- it quietly takes the branch it should not.
{
    echo "; generated by build.sh -- do not edit"
    printf 'DMSTALLT EQU    %s\n' "${DMSTALLT:-0}"
    printf 'DMLAG   EQU     %s\n' "${DMLAG:-0}"
    printf 'DMTVSTD EQU     %s\n' "$tvstd"
} > build/cfg.inc

# The relay this image talks to when no Lobby has written the room appkey.
# Regenerated every run so a stale value cannot survive an environment change.
{
    echo "; generated by build.sh -- do not edit"
    printf 'UENDPT: DB      "%s"\n' "${ENDPOINT:-N:TCP://127.0.0.1:9603/}"
    echo "        DB      0"
} > build/endpoint.inc

# The player name, padded to eight. The relay accepts 2-8 of [A-Z0-9] and
# dedupes by suffix, so two consoles built from the same tree still pair.
python3 - "${PLAYER:-DODGEM}" > build/playername.inc <<'EOF'
import re, sys
n = re.sub(r"[^A-Z0-9]", "", sys.argv[1].upper())[:8] or "DODGEM"
print("; generated by build.sh -- do not edit")
print('DMNAME: DB      "%s"' % n.ljust(8))
EOF

python3 tools/dmphase.py rom/dodgem.bin build/dm_org.lst > build/phase.log
python3 tools/dmbanks.py build/dm_org.lst build/dm_org.asm build

# THE TAIL IS ASSEMBLED FIRST. mktail.py turns the addresses its routines land
# at into build/tail.inc, which every bank includes -- so a bank cannot be
# assembled against a transport that has not been placed yet.
assemble dmtail
# The banks are assembled separately, so they need the tail's addresses as
# constants -- and a hand-maintained list of them would go stale in silence the
# moment a byte is added to any routine above them. Read them back out of the
# tail's own listing instead.
python3 tools/mktail.py build/dmtail.lst \
    FNRW,FNARM,FNCHK,FNBEG,FNPB,FNPW,FNGO,FNACK,\
FNROWA,FNCHR,FNENDR > build/tail.inc
tail -1 build/tail.inc | sed 's/^; */  tail: /'
p2bin build/dmtail.p build/dmtail.bin -r '$1800-$1FFF' -l 255 -q

for b in $BANKS; do
    # The four game banks are GENERATED into build/; the boot bank is written
    # by hand and lives in src/. AS resolves INCLUDE against its own cwd, which
    # is why assemble() takes the directory rather than guessing.
    d=build; [ -f "src/$b.asm" ] && d=src
    assemble "$b" "$d"
    python3 tools/checkbanks.py "build/$b.lst" $((0x1800)) "$b"
    p2bin "build/$b.p" "build/$b.bin" -r '$1000-$17FF' -l 255 -q
    rm -f "build/$b.p"
done

# Two spare banks, filled with $FF. NOT with $00: $00 is BRK, and a bank that
# is all BRK is a bank that runs if it is ever entered by accident. $FF is ISC
# abs,X, which is no better as code but is what p2bin's own filler is
# everywhere else in this image, so a stray bank looks like every other gap.
python3 - <<'EOF'
open("build/dmspare.bin", "wb").write(b"\xFF" * 2048)
EOF

cat build/dmg0.bin build/dmg1.bin build/dmg2.bin build/dmg3.bin \
    build/dmboot.bin build/dmspare.bin build/dmspare.bin \
    build/dmtail.bin > build/dodgem.bin
rm -f build/dmtail.p

# Every label in the pinned span is at one address in every bank. A pointer
# built in one bank and followed in another depends on it, and the failure is
# silent until the event that follows the pointer happens.
# The stack is the top six bytes of the same 128 that hold the game, so every
# level the netcode nests is a byte of Dodge 'Em. Static, because the runtime
# version needs a networked match to exercise these paths at all.
# The netcode's cells, for the Lua harnesses. Taken from the assembler rather
# than written down: emu/latency.lua once tapped three cells this port had
# moved and reported nought rounds while 588 completed.
python3 tools/mksyms.py build/dmg0.lst build/dmsyms.lua \
    DMENT DMERR DMTICK DMNST DMRWAT DMCRCV DMADV DMLOC0 DMRIN0 \
    DMSWA DMSWB DMTR4 DMTR5

python3 tools/dmstack.py build/dmg0.lst build/dmg1.lst build/dmg2.lst \
    build/dmg3.lst build/dmboot.lst

python3 tools/check_pins.py $((0xFE2E)) $((0xFED7)) \
    build/dmg0.lst build/dmg1.lst build/dmg2.lst build/dmg3.lst

stampclaim build/dodgem.bin
python3 tools/checkrom_filter.py "$VCS/tools/checkrom.py" build/dodgem.bin \
    "build/dmg0.lst" "build/dmg1.lst" "build/dmg2.lst" "build/dmg3.lst" \
    "build/dmboot.lst" "build/dmspare.lst" "build/dmspare.lst" \
    "build/dmtail.lst@0x1800"
exit 0
