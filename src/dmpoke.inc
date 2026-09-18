; dmpoke.inc -- how the evicted game state is WRITTEN.
;
; $AC-$B4 and $BC-$C2 live in a cartridge text plane now (see dmdefs.inc), so
; the game can still READ them with an ordinary indexed load -- the planes are
; 128-byte aligned, `lda DMDOTS,x` is four cycles, exactly what `lda $AC,x`
; cost -- but it cannot STORE to them. A store into $1800-$1AFF does not reach
; the cartridge; those pages are cart-to-console.
;
; So a write becomes four stores to the blit port and one FN_BLIT_POKE. That
; costs about 30 cycles where a `sta zp,x` cost 4, which is affordable only
; because of WHICH blocks were evicted: the dot bitmap is written when a dot is
; actually eaten, and player B's saved state at a round end. Neither is a
; per-frame cost. PORTING.md 5.2 is the account of why the 54-byte playfield
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
        sta     FNRSEL+FH_BSL   ; src low = the byte; a one-shot hotspot takes
                                ;   the data from the store, so this IS the
                                ;   value, not an address of it
        txa
        clc
        adc     #DMDOTSO&$FF
        sta     FNRSEL+FH_BDL
        lda     #DMDOTSO>>8
        sta     FNRSEL+FH_BDH
        lda     #FB_POKE
        sta     FNRSEL+FH_BGO   ; fire; the transform rides in the store's data
        rts

DMPOKEB:
        sta     FNRSEL+FH_BSL
        txa
        clc
        adc     #DMSAVBO&$FF
        sta     FNRSEL+FH_BDL
        lda     #DMSAVBO>>8
        sta     FNRSEL+FH_BDH
        lda     #FB_POKE
        sta     FNRSEL+FH_BGO
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

; ---------------------------------------------------------------------------
; DMBWAIT -- spin until the last blit has landed.
;
; Called before a blit, not after. In emulation FNBGEN has already moved by the
; time this reads it and the loop falls straight through, which is exactly the
; fidelity trap fujitcp.h warns about for ACKSEQ: a client that forgets to poll
; passes in emulation and fails on hardware. So the poll is written to be
; correct on hardware and free in emulation, and never the other way round.
; ---------------------------------------------------------------------------
DMBWAIT:
        lda     FNBGEN
DMBW1:
        cmp     FNBGEN
        beq     DMBW1
        rts
