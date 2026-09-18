"""patches.py -- the declared patch map for networked Dodge 'Em.

The family's discipline: the original source is never edited, every change to
it is DECLARED here, and check_patch.py fails the build on any difference
between the built image and the cartridge dump that is not on this list. A
patch that changes nothing and a change that was never declared are both build
failures.

WHAT IS DIFFERENT HERE: the anchor is an ADDRESS AND THE BYTES THAT MUST BE AT
IT, not a line number of the generated disassembly.

The sibling ports anchor on `line=` plus the exact text that line must contain,
and Tennis's own header warns what that costs: rom/tennis.asm is generated, so
its line numbers move whenever the code/data map changes, and "if
tools/tennis.cfg changes, expect to re-anchor this file, and let the errors
tell you where." Dodge 'Em has 39 declared sites against Tennis's handful, and
re-anchoring 39 of them by hand after every .cfg experiment is not a cost worth
paying for a property the address already has. An address does not move when
the disassembly is recut; the opcode bytes at it are just as specific as the
source text; and resolve() below turns an address into a line number, so the
error message is still "line 845 said something else".

EVERY PATCH IN THE VBLANK BAND MUST BE CYCLE-PRESERVING AS WELL AS
SIZE-PRESERVING. LF003 positions sprites by counting cycles and then strobing
RESP0/RESP1, and RESPx fixes an object's X from the raster position at the
instant it executes. Video Olympics 3.20 is the account of what it costs to
learn this the other way round: one cycle, found only at thirty seconds, in a
gate that had passed at ten for its whole life.
"""

# ---------------------------------------------------------------------------
# M3: the input shim. 24 sites -- far more than any sibling (Combat 7, Video
# Olympics 7, Tennis 5, Dragster 4) -- and every one of them is both size- and
# cycle-preserving, which is luck rather than design.
#
# SWCHA and SWCHB are read absolute (AD lo hi, 4 cycles). Redirecting them to a
# zero-page shadow through ABSOLUTE addressing keeps all three bytes and all
# four cycles. AS shortens `LDA $80` to zero page on its own, so the shadows
# MUST be written with the `>` force-long prefix or every following byte moves.
#
# INPT4/INPT5 are already zero page in the TIA and the shadows are zero page in
# the RIOT, so those four are the same opcode and the same three cycles.
#
# THE EIGHT TURN-POINT SITES NEED NOTHING SPECIAL, and that is worth saying
# because it looks as though they should. They decode different nibbles --
# $F608 does LSR/LSR/LSR/BCC on the right port's bits while $F627 does
# BPL/ASL/BMI on the left's -- but they are all reading THE SAME REGISTER. A
# faithful synthetic SWCHA, host's stick in bits 7-4 and guest's in 3-0, makes
# every decode work unchanged. The shim never has to know which nibble a site
# wants and never has to look at $98.
#
# That matters because $98 bit 7 FLIPS DURING THE MATCH -- LF4F2 does
# `LDA $98 / EOR #$80 / STA $98` -- and it says who is dodging this round. Mix
# in PORT space and let the game's own `BIT $98` do the rest. This is Tennis
# 2.4's two index spaces in a new place.
# ---------------------------------------------------------------------------

INPUTS = [
    # (address, expected bytes, replacement source, why)
    (0xF05C, "AD 82 02", "lda     >DMSWB", "starting layout, from P1 difficulty"),
    (0xF0F5, "AD 82 02", "lda     >DMSWB", "colour/BW and the player colours"),
    (0xF156, "AD 82 02", "lda     >DMSWB", "RESET"),
    (0xF162, "AD 82 02", "lda     >DMSWB", "SELECT -- walks $94 AND $96"),
    (0xF4B3, "AD 82 02", "lda     >DMSWB", "difficulty, end of round"),
    (0xF540, "AD 82 02", "lda     >DMSWB", "difficulty, chase-car AI"),
    (0xF585, "AD 82 02", "lda     >DMSWB", "colour/BW, attract"),
    (0xF631, "AD 82 02", "lda     >DMSWB", "difficulty, turn point 1"),
    (0xF774, "AD 82 02", "lda     >DMSWB", "difficulty, turn point 3"),

    (0xF608, "AD 80 02", "lda     >DMSWA", "turn point 1, right port"),
    (0xF627, "AD 80 02", "lda     >DMSWA", "turn point 1, left port"),
    (0xF6B1, "AD 80 02", "lda     >DMSWA", "turn point 2, right port"),
    (0xF6CE, "AD 80 02", "lda     >DMSWA", "turn point 2, left port"),
    (0xF74B, "AD 80 02", "lda     >DMSWA", "turn point 3, right port"),
    (0xF76A, "AD 80 02", "lda     >DMSWA", "turn point 3, left port"),
    (0xF7F4, "AD 80 02", "lda     >DMSWA", "turn point 4, right port"),
    (0xF811, "AD 80 02", "lda     >DMSWA", "turn point 4, left port"),
    (0xFB41, "AD 80 02", "lda     >DMSWA", "LFB3D, right player dodging"),
    (0xFB51, "AD 80 02", "lda     >DMSWA", "LFB51, left player dodging"),
    (0xFBDB, "AD 80 02", "lda     >DMSWA", "attract-mode wake-up"),

    (0xFB37, "A5 3D", "lda     DMTR5", "LFB33, right trigger"),
    (0xFB4A, "A5 3D", "lda     DMTR5", "LFB3D, right trigger"),
    (0xFB3A, "A5 3C", "lda     DMTR4", "LFB3A, left trigger"),
    (0xFB56, "A5 3C", "lda     DMTR4", "LFB51, left trigger"),
]

# ---------------------------------------------------------------------------
# M2: the twelve pointer high bytes.
#
# Dodge 'Em's data lives at $FD62-$FF33, which rebased into the cartridge
# window is $1D62-$1F33 -- the control page, the write-only TX stream and the
# status page. Every table moves into a bank, and the ~35 ABSOLUTE references
# re-point themselves once the tables carry labels.
#
# These twelve do not, because they are IMMEDIATES: `lda #$FE / sta $A1` builds
# a pointer the kernel then dereferences with `lda ($A0),y`. A computed pointer
# is invisible to static analysis, so checkrom.py cannot see a missed one and
# `make mailbox` is the only gate that can.
#
# The severity is not uniform and the worst case is what to design against. A
# stray read of $1E** corrupts a transaction in flight. A stray read of
# $1D80-$1DEF SWITCHES THE BANK OUT FROM UNDER THE RUNNING KERNEL -- and
# $FD80-$FDEF is 112 bytes of live sprite data reached through exactly these
# pointers.
#
# $F052 is `LDA #$FF` and is NOT one of these: it seeds the dot bitmap. It is
# listed so that the next person to grep for `#$FE|#$FF` does not add it.
# ---------------------------------------------------------------------------

POINTERS = [
    (0xF078, "A9 FE", "lda     #(LFE6C)>>8", "car sprite, via $A0/$A1"),
    (0xF519, "A9 FE", "lda     #(LFE64)>>8", "car sprite, via $BA/$BB"),
    (0xF522, "A9 FE", "lda     #(LFE64)>>8", "car sprite, via $A0/$A1"),
    (0xF52B, "A9 FE", "lda     #(LFE64)>>8", "car sprite, via $A7/$A8"),
    (0xF68E, "A9 FE", "lda     #(LFE6C)>>8", "car sprite, via $A0/$A1"),
    (0xF7D1, "A9 FE", "lda     #(LFE6C)>>8", "car sprite, via $A0/$A1"),
    (0xFB61, "A9 FE", "lda     #(LFE6C)>>8", "car sprite, via $A7/$A8"),
    (0xFC4F, "A9 FE", "lda     #(LFE94)>>8", "all six score digits at once"),
    (0xFC77, "A9 FE", "lda     #(LFE94)>>8", "digit wrap, $8E/$8F"),
    (0xFC89, "A9 FE", "lda     #(LFE94)>>8", "digit wrap, $90/$91"),
    (0xFCB9, "A9 FE", "lda     #(LFE94)>>8", "digit wrap, $88/$89"),
    (0xFCCB, "A9 FE", "lda     #(LFE94)>>8", "digit wrap, $8A/$8B"),
]

NOT_A_POINTER = [(0xF052, "A9 FF", "seeds the dot bitmap, not a pointer high byte")]

# ---------------------------------------------------------------------------
# M0c: the evicted blocks.
#
# $AC-$B4 (the per-row dot bitmap) and $BC-$C2 (player B's saved state) move
# into a cartridge text plane so the netcode has sixteen bytes of persistent
# zero page. PORTING.md 5.2 is why those two and not the 54-byte playfield
# streams: neither is on the kernel's path, and both are written at
# frequencies measured in events per second rather than per frame.
#
# A READ is free and costs exactly what it did: the planes are 128-byte
# aligned, so `lda DMDOTS,x` with x <= 8 cannot page-cross and is four cycles,
# the same as `lda $AC,x`. It is one byte longer, which is why the banks are
# re-laid from source rather than patched in place.
#
# A WRITE cannot be an instruction at all -- the planes are cart memory. It
# becomes four stores to the blit port through DMPOKE, and the four dot sites
# fold their EOR into it:
#
#       lda $AC,x / and $AB / beq skip / eor $AC,x / sta $AC,x
#   ->  lda DMDOTS,x / and $AB / beq skip / eor DMDOTS,x / jsr DMPOKED
# ---------------------------------------------------------------------------

EVICTED = [
    (0xF054, "95 AC", "jsr     DMSEEDD", "seed all nine rows to $FF"),
    (0xF5AB, "B5 BC", "lda     DMSAVB,x", "LF5A0 swap, read B"),
    (0xF5B5, "95 BC", "jsr     DMPOKEB", "LF5A0 swap, write B"),
    (0xF897, "B5 AC", "lda     DMDOTS,x", "dot test, turn point 1"),
    (0xF89D, "55 AC", "eor     DMDOTS,x", "dot clear, turn point 1"),
    (0xF89F, "95 AC", "jsr     DMPOKED", "dot store, turn point 1"),
    (0xF8E2, "B5 AC", "lda     DMDOTS,x", "dot test, turn point 2"),
    (0xF8E8, "55 AC", "eor     DMDOTS,x", "dot clear, turn point 2"),
    (0xF8EA, "95 AC", "jsr     DMPOKED", "dot store, turn point 2"),
    (0xF927, "B5 AC", "lda     DMDOTS,x", "dot test, turn point 3"),
    (0xF92D, "55 AC", "eor     DMDOTS,x", "dot clear, turn point 3"),
    (0xF92F, "95 AC", "jsr     DMPOKED", "dot store, turn point 3"),
    (0xF96C, "B5 AC", "lda     DMDOTS,x", "dot test, turn point 4"),
    (0xF972, "55 AC", "eor     DMDOTS,x", "dot clear, turn point 4"),
    (0xF974, "95 AC", "jsr     DMPOKED", "dot store, turn point 4"),
]

ALL = [("INPUTS", INPUTS), ("POINTERS", POINTERS), ("EVICTED", EVICTED)]
