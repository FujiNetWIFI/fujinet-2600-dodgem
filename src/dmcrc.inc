; dmcrc.inc -- the sim checksum.
;
; One byte, riding every input record, and the only thing that tells two
; consoles they have stopped agreeing. Not an integrity check on the wire --
; IR_SEED already salts an XOR over each frame for that -- but on the
; SIMULATION.
;
; WHAT IT COVERS, and the two rules that decide it:
;
;   Combat 4.21 -- it must cover every cell that SELECTS behaviour, not only
;   the cells behaviour writes.
;
;   Video Olympics 3.15, the converse -- a cell the netcode fills is not state
;   the netcode should check.
;
; IN: the game variables that steer it, the mode and run state and level and
; active player and score, the track and car state, player A's saved block, and
; the per-row dot bitmap -- read from the cartridge text plane it now lives in,
; so a poke lost through the blit port shows up as a desync rather than as a
; dot that quietly came back.
;
; OUT, each for its own reason:
;
;   $80 $87 $A9 $AA   the synthetic controller. The netcode fills them.
;   $99 $9A           kernel scratch, in motion when the sample is taken.
;   $9F               THE BLACK-AND-WHITE SWITCH, and this is the subtle one.
;                     $F0F5 stores $07 or $F7 there from SWCHB bit 3, and the
;                     four turn points read it as `LDX $9F / BNE`. Both values
;                     are non-zero so BEHAVIOUR IS IDENTICAL -- but two
;                     consoles whose players set the switch differently hold
;                     different bytes for ever. In the checksum it would report
;                     a desync between two machines that agree about
;                     everything. B/W is local here, like Dragster's.
;   $C3-$F8           the six playfield streams, 54 bytes. Out for COST, not
;                     for principle: they are the dot bitmap and the track
;                     tables rendered, mutated by the same code path, so a
;                     divergence in them is a divergence in the bitmap one tick
;                     earlier. Sampling them would cost ~700 cycles in a band
;                     whose worst frame leaves 640.
;
; Sampled AT A TICK BOUNDARY and nowhere else (Combat 4.5): a quantity sampled
; only on the ticks that RAN is a fact about the local stall pattern, which is
; the one thing two consoles differ in by design.
;
; The accumulator stays in A for the whole walk. Keeping it in a cell would
; cost an LDA and an STA per byte -- six cycles times thirty-six -- in the one
; band this has to fit inside.

; DMCRCR -- fold `Y` bytes starting at zero-page `X` into A.
; A rotate before each add, so a transposition is not invisible the way a
; plain sum would make it.
DMCRCR:
        asl
        adc     $00,x
        inx
        dey
        bne     DMCRCR
        rts

DMCRC:
        lda     #0
        ldx     #$81            ; the variables that steer it
        ldy     #6
        jsr     DMCRCR
        ldx     #$94            ; mode, run, level, active player, score
        ldy     #5
        jsr     DMCRCR
        ldx     #$9B            ; the dodging car and its lane
        ldy     #4
        jsr     DMCRCR
        ldx     #$A2            ; the chase car, and the round's counters
        ldy     #4
        jsr     DMCRCR
        ldx     #$AB            ; the one-hot column mask
        ldy     #1
        jsr     DMCRCR
        ldx     #$B5            ; player A's saved block
        ldy     #7
        jsr     DMCRCR

; The dot bitmap, out of the cartridge plane it was evicted into. Read with an
; absolute index because it is not in zero page any more, which is the whole
; point of it being there.
        ldx     #8
DMCRCP:
        asl
        adc     DMDOTS,x
        dex
        bpl     DMCRCP

; ...and the store belongs here rather than in the caller, so that DMCAP can
; reach this with a JMP instead of a JSR. See the note there: it is a level of
; stack, and on this console a level of stack is a byte of the playfield.
        sta     DMCRCV
        rts
