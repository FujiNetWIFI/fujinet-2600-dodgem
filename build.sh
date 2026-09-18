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
    local b=$1 d=${2:-src}
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
    "$P2BIN" build/dm_org.p build/dm_org.bin -r '$F000-$FFFF' -l 255 -q
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
if [ "${1:-}" = "zp" ]; then
    # It needs the DUMP and the ASSEMBLER'S LISTING: the dump for the opcodes,
    # the listing for the code/data split, because a linear walk through a data
    # table is misaligned garbage that invents references. build/dm_org.lst is
    # verify-org's output, so make that first if it is not there.
    [ -f build/dm_org.lst ] || "$0" verify-org
    python3 tools/zpmap.py rom/dodgem.bin build/dm_org.lst
    exit 0
fi

echo "build.sh: nothing else is implemented yet -- see PORTING.md for the ladder" >&2
exit 1
