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
# ...AND THE LOW BYTES, AND THE COMPARISONS. Rewriting only the high bytes is
# a trap that builds, runs, and draws a plausible screen.
#
# `LDA #$94 / STA $8A` is the other half of every pointer, and `#$94` is a
# literal that says nothing about where the table is. With only the high byte
# patched, the digit pointer in bank G0 came out as $1494 while LFE94 was
# actually at $143A -- off by $5A, reading glyphs out of the middle of the
# track tables. make det caught it; nothing static could, because both halves
# are immediates and neither is wrong on its own.
#
# The four CMP sites are the same mistake in a third disguise. `CMP #$CA` is
# the digit-table WRAP CHECK and $CA is LFE94+54, the end of the ten 6-byte
# glyphs -- a table-relative address written as a constant. Rewritten with the
# table, it keeps meaning what it meant.
POINTER_LOWS = [
    (0xF074, "A9 6C", "lda     #(LFE6C)&$FF", "car sprite -> $A0"),
    (0xF515, "A9 64", "lda     #(LFE64)&$FF", "car sprite -> $BA"),
    (0xF51E, "A9 64", "lda     #(LFE64)&$FF", "car sprite -> $A0"),
    (0xF527, "A9 64", "lda     #(LFE64)&$FF", "car sprite -> $A7"),
    (0xF68A, "A9 6C", "lda     #(LFE6C)&$FF", "car sprite -> $A0"),
    (0xF7CD, "A9 6C", "lda     #(LFE6C)&$FF", "car sprite -> $A0"),
    (0xFB5D, "A9 6C", "lda     #(LFE6C)&$FF", "car sprite -> $A7"),
    (0xFC41, "A9 94", "lda     #(LFE94)&$FF", "all six score digits at once"),
    (0xFC7B, "A9 94", "lda     #(LFE94)&$FF", "digit wrap -> $8E"),
    (0xFC85, "A9 94", "lda     #(LFE94)&$FF", "digit wrap -> $90"),
    (0xFCBD, "A9 94", "lda     #(LFE94)&$FF", "digit wrap -> $88"),
    (0xFCC7, "A9 94", "lda     #(LFE94)&$FF", "digit wrap -> $8A"),
    (0xFC73, "C9 CA", "cmp     #(LFE94+54)&$FF", "digit table end, $8E"),
    (0xFC81, "C9 CA", "cmp     #(LFE94+54)&$FF", "digit table end, $90"),
    (0xFCB5, "C9 CA", "cmp     #(LFE94+54)&$FF", "digit table end, $88"),
    (0xFCC3, "C9 CA", "cmp     #(LFE94+54)&$FF", "digit table end, $8A"),

    # A pointer built by 16-BIT ARITHMETIC rather than loaded whole:
    #
    #     $F463  LDA #$6C        ; LFE6C, low
    #     $F466  ADC #$08        ; + 8
    #     $F46C  LDA #$00
    #     $F46E  ADC #$FE        ; LFE6C, high, taking the carry
    #
    # Both halves of LFE6C are here and neither is next to its STA, which is
    # why the first sweep for pointer constants missed them: it looked for
    # `LDA #imm` immediately followed by `STA zp`. The +8 is untouched -- it is
    # an offset into the table, not an address -- and rewriting the base keeps
    # the carry behaviour exactly, because the high byte is still added with
    # whatever the low add produced.
    #
    # make det found this: the crash animation set $A7/$A8 to G3's PACKED copy
    # of the table instead of the pinned one, and the two builds diverged 134
    # frames in, when the first car crashed.
    (0xF463, "A9 6C", "lda     #(LFE6C)&$FF", "crash animation, low half"),
    (0xF46E, "69 FE", "adc     #(LFE6C)>>8",  "crash animation, high half"),

    # ...and the loop's TERMINATION TEST, which is the same constant in a
    # third disguise:
    #
    #     $F465  CLC / ADC #$08 / STA $A0 / STA $A7   ; step the animation
    #     $F49C  LDA $A0 / CMP #$8C / BNE $F465       ; four frames of it
    #
    # $8C is LFE6C+32 -- where the walk stops -- written as a constant. With
    # the base relocated and the test left alone the comparison simply never
    # matched, so the crash animation ran past its end, and the `DEC $96`
    # inside the loop took the sound counter with it.
    #
    # One patch, six diverging cells: $96, $9B, $A0, $A2, $A4 and $A7 all came
    # back together.
    (0xF49E, "C9 8C", "cmp     #(LFE6C+32)&$FF", "crash animation, end of walk"),
]

# ---------------------------------------------------------------------------
# M4: the stall gate.
#
# A stall is a frame drawn normally with the game-logic chain skipped. Dodge
# 'Em advances its simulation in two places, so there are two gates: the dot
# engine in vblank (folded into DMTOG1, which is already a bank switch) and the
# movement chain in overscan, here.
#
# $F4C6's `LDA $81` is displaced rather than duplicated, so the flags $F4C8
# consumes are the ones it always had.
GATES = [
    # AT THE HEAD OF THE BAND, NOT AT THE MOVEMENT CHAIN.
    #
    # This was $F4C6, which gates LF5BF's turns, LF5A0's swap and the $82/$97
    # counters -- and leaves the three DELAY COUNTDOWNS at $F42E-$F452 running
    # on every frame, stalled or not. Video Olympics' PORTING.md 3.16 is the
    # rule: everything left ungated becomes a function of the local stall
    # pattern, and the stall pattern is the one thing two consoles differ in by
    # design. Measured: the pair disagreed on $86 from their first tick.
    #
    # $F42E is the first instruction after LF577 and everything from there to
    # the band's spin is simulation, so one gate here covers all of it.
    (0xF42E, "A5 86", "jmp     DMOVGATE", "overscan: the whole chain"),
]

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
    (0xF054, "95 AC", "jsr     DMPOKED", "LF032 seeds row X to $FF"),
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

# ---------------------------------------------------------------------------
# M2a: the seams.
#
# Five places where control leaves a bank, found by the assembler rather than
# by reading: packing each bank's regions makes every cross-bank reference an
# undefined symbol. Two more are FALL-THROUGH seams, where a region simply runs
# off its end into another bank with no symbol involved; those are not patches
# and tools/dmbanks.py appends the switch itself.
#
# At all five, A, X and Y are dead -- each lands on an instruction that loads
# its own registers -- so DMGOTO is free to clobber A and X and to carry the
# entry index in Y. That is a happier position than Tennis, where Y had to
# survive the switch and the seam had to be moved to suit.
#
# THE DOT ENGINE'S FOUR RETURNS ARE THE INTERESTING ONES. `JSR LF859` at $F228
# is a CALL, and a bank switch resets the stack, so nothing can return through
# one. The four outermost RTS sites of the LF859 subtree -- the ones that match
# that JSR rather than an inner call -- each become a switch back to G0 at its
# second entry. They were found by walking the subtree WITHOUT following JSRs,
# which is what distinguishes an outermost return from an inner one; guessing
# would have meant either a hang or a return into the middle of a table.
SEAMS = [
    (0xF228, "20 59 F8", "jmp     DMTOG1",  "G0 -> G1: into the dot engine"),
    # A BRANCH CANNOT REACH A STUB, and that is not a detail of where the stub
    # was put. The kernel is 476 bytes and this branch sits 371 bytes into it,
    # so no position for the stub is within reach of both ends of the bank.
    # Inverting the branch over a jump is the only shape that works, and it is
    # the one place in this port where a patch is neither size- nor
    # cycle-preserving: two bytes become five, and a taken branch becomes a
    # branch plus a jump. It is the last instruction of the picture, with a
    # WSYNC on the far side, so there is nothing left in the frame for it to
    # push out of place -- `make frames` is the gate that says so.
    (0xF3B7, "30 67",    "bpl     *+5\n        jmp     DMTOG3",
     "G2 -> G3: kernel into overscan, branch inverted over a jump"),
    (0xF4EF, "4C E4 F0", "jmp     DMTOG0",  "G3 -> G0: overscan to frame top"),
    (0xF9E4, "60",       "jmp     DMTOG0R", "G1 -> G0: dot engine returns"),
    (0xFA4A, "60",       "jmp     DMTOG0R", "G1 -> G0: dot engine returns"),
    (0xFAB6, "60",       "jmp     DMTOG0R", "G1 -> G0: dot engine returns"),
    (0xFB23, "60",       "jmp     DMTOG0R", "G1 -> G0: dot engine returns"),
]

# ---------------------------------------------------------------------------
# Work INSERTED rather than substituted. The packer places each bank's regions
# itself, so a line can be added without displacing anything: the labels move
# and the assembler re-resolves them.
#
# Both of these fill the synthetic controller, and WHERE they are is the whole
# point. DMMIX first ran from each bank's entry dispatcher, which is before the
# band's timer is armed -- so its ~46 cycles delayed the arm, delayed the spin
# that waits the timer out, and lengthened the frame. emu/frames.lua measured
# 264 scanlines against stock's 262, on every frame, and emu/seams.lua found
# the same shape at the other end: a switch at scanline 263 with nothing left
# to absorb it.
#
# Inside the band, the spin at the far end swallows it, which is Video
# Olympics' PORTING.md 3.13 -- the only safe home for work whose length varies
# is inside a timed band.
TIMERS = [
    # The overscan band, one tick shorter.
    #
    # The switch back to G0 is the one seam with no wait on its far side: the
    # band's spin has already expired, and the next WSYNC is four instructions
    # into the next frame at $F0EA. Thirty-odd cycles of DMGOTO and dispatch
    # therefore push past the end of the scanline the spin ended on, and the
    # WSYNC lands a line late -- 263 where stock measures 262, on every frame.
    #
    # Giving the band back one 64-cycle tick moves the spin's exit a line
    # earlier and the switch fits in the room that makes. It costs the overscan
    # band 64 cycles of slack, which is the band the netcode does NOT run in
    # (dmdefs.inc picks vblank), and `make slack` is what says the game still
    # fits in what is left.
    (0xF426, "A9 24", "lda     #$23", "overscan band: one tick for the seam"),
]

INSERTS = [
    (0xF145, "        jsr     DMMIXV", "vblank: steps the clock, then derives"),
    (0xF42B, "        jsr     DMMIXO", "overscan: re-derives only -- a clock "
                                       "stepped twice a frame is not a clock"),
]

ALL = [("INPUTS", INPUTS), ("POINTERS", POINTERS),
       ("POINTER_LOWS", POINTER_LOWS), ("EVICTED", EVICTED), ("SEAMS", SEAMS),
       ("TIMERS", TIMERS), ("GATES", GATES)]
