; dmpoke.inc -- how the evicted game state is WRITTEN.
;
; $AC-$B4 and $BC-$C2 live in a cartridge text plane now (see dmdefs.inc), so
; the game can still READ them with an ordinary indexed load -- the planes are
; 128-byte aligned, `lda DMDOTS,x` is four cycles, exactly what `lda $AC,x`
; cost -- but it cannot STORE to them. A store into $1800-$1AFF does not reach
; the cartridge; those pages are cart-to-console.
;
; So a write becomes four stores to the blit port and one FN_BLIT_POKE. That
; costs about 100 cycles where a `sta zp,x` cost 4, which was justified here by
; WHICH blocks were evicted: the dot bitmap is written when a dot is actually
; eaten, and player B's saved state at a round end, so neither is a per-frame
; cost.
;
; THAT WAS WRONG, AND IT WAS NEVER MEASURED. LF032 -- the track setup -- seeds
; all nine dot rows to $FF inside the same loop that lays down the six
; playfield streams, and it runs on very nearly every frame: 370 frames in 400
; fired nine blits. Nine blits is about 900 cycles, and `make slack` says the
; vblank band's worst frame leaves 576. The netcode's own tick-boundary work
; then had nowhere to fit, the band expired inside it, and the frame came out
; 358 lines instead of 261. PORTING.md 14.
;
; THE SEED IS A WRITE OF A VALUE THE PLANE USUALLY ALREADY HOLDS -- $FF over a
; row of dots nobody has eaten yet -- so each site now compares first and fires
; only on a real change. Four cycles to find out, against a hundred to do it
; anyway. The plane is the authoritative storage, so a write of the byte it
; already contains cannot be observed by anything: this is a cost removed, not
; a semantic changed. PORTING.md 5.2 is the account of why the 54-byte playfield
; streams -- the obvious choice, being the biggest -- would have been the worst
; one: the kernel reads those twice per scanline pair.
;
; THE BLIT PORT HAS NO QUEUE. fuji_mailbox.h is explicit: a second blit fired
; before the first has run loses the first on hardware and notices nothing in
; emulation, where the blit happens inside the store. The dot loop can eat more
; than one dot in a pass, so the generation poll is not optional and it is done
; BEFORE the blit rather than after -- waiting afterwards would pay for a
; settle nobody needs when no second blit follows.

; ---------------------------------------------------------------------------
; DMPOKED -- DMDOTS[X] = A.   DMPOKEB -- DMSAVB[X] = A.
;
; Preserves X, which every caller still needs as its row index. Clobbers A and
; the flags, which no caller needs: each of the five sites goes straight into a
; JSR whose own first instruction sets the flags it branches on.
; ---------------------------------------------------------------------------
DMPOKED:
        cmp     DMDOTS,x        ; unchanged? then there is nothing to write
        beq     DMPOKE9
        sta     FNRSEL+FH_BSL   ; src low = the byte; a one-shot hotspot takes
                                ;   the data from the store, so this IS the
                                ;   value, not an address of it
        txa
        clc
        adc     #DMDOTSO&$FF
        sta     FNRSEL+FH_BDL
        lda     #DMDOTSO>>8
        sta     FNRSEL+FH_BDH
        jmp     DMFIRE

DMPOKEB:
        cmp     DMSAVB,x        ; unchanged? then there is nothing to write
        beq     DMPOKE9
        sta     FNRSEL+FH_BSL
        txa
        clc
        adc     #DMSAVBO&$FF
        sta     FNRSEL+FH_BDL
        lda     #DMSAVBO>>8
        sta     FNRSEL+FH_BDH
        ; fall through

; ---------------------------------------------------------------------------
; DMFIRE -- fire the blit and wait for it to LAND.
;
; The generation counter is snapshotted BEFORE the store and waited on after,
; which is the only ordering that works. The first version of this read FNBGEN
; and then spun until it differed from itself; nothing was ever going to change
; it, and the console hung on the first poke with every RAM cell still zero --
; which reads as a ROM that never started rather than a routine that never
; returned.
;
; Correct on hardware, where core0 runs the blit some microseconds later, and
; free in emulation, where it lands inside the store and the compare falls
; through on the first pass. Written that way round on purpose: fujitcp.h's
; note about ACKSEQ is the same trap, and a client that polls only because the
; emulator lets it get away with not polling fails on the cartridge.
DMFIRE:
        lda     FNBGEN
        sta     DMTMP
        lda     #FB_POKE
        sta     FNRSEL+FH_BGO   ; fire; the transform rides in the store's data
DMFIRE1:
        lda     FNBGEN
        cmp     DMTMP
        beq     DMFIRE1
DMPOKE9:
        rts

; The low byte of the destination is added to X without handling a carry, and
; that is safe because of where the two blocks were PLACED, not because of what
; any caller passes. Both offsets end in $0 and both blocks are far shorter
; than the sixteen slots that would reach the next page, so assert it here --
; at the equates -- rather than trusting a comment next to the ADC.
        IF      (DMDOTSO&$FF)+8 > $FF
        ERROR   "DMDOTS is placed so that the dot row index carries"
        ENDIF
        IF      (DMSAVBO&$FF)+6 > $FF
        ERROR   "DMSAVB is placed so that the save-block index carries"
        ENDIF
