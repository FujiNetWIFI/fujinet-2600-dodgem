; dmcap.inc -- the tick boundary.
;
; ADVANCE THE TICK, SAMPLE THE CHECKSUM AND CAPTURE THE STICK AS ONE
; INDIVISIBLE ACT, on a boundary that actually advanced -- or do none of them.
; That is Combat's PORTING.md 4.6, and 4.14 is the reason: if a quantity and
; its label are sampled at different moments, the relationship between them is
; a fact about the local machine rather than about the simulation. A record,
; once written, is never revised.
;
; The local ring is a THREE-BYTE SHIFT REGISTER rather than a ring indexed by
; tick. At d = 2 the live slots are t, t-1 and t-2 and nothing older is ever
; wanted, so a shift is both smaller and impossible to index wrongly -- there
; is no modulo to get off by one.

DMCAP:
        jsr     DMTICKB         ; Z set only on the frame that begins a tick
        bne     DMCAP9

        inc     DMTICK

; The shift, oldest first so nothing is overwritten before it is read.
        lda     DMLOC1
        sta     DMLOC2
        lda     DMLOC0
        sta     DMLOC1

; The capture. Built here in PORT space, from the live console, with the
; hardware's active-low sense intact: bit 7 the trigger, 6 the difficulty, 5
; SELECT, 4 RESET and the low nibble this console's stick. IDLE is $FF and a
; zero byte would read as every switch pressed at once (Combat 4.8).
        lda     SWCHA
        and     #$F0            ; this console's own port is the LEFT one; the
        lsr                     ;   guest's ROM puts its stick in the same
        lsr                     ;   nibble and the relay never looks inside
        lsr
        lsr
        sta     DMTMP
        lda     SWCHB
        and     #$03            ; SELECT and RESET, active low
        asl
        asl
        asl
        asl
        ora     DMTMP
        sta     DMTMP
        lda     SWCHB
        and     #$80            ; this console's difficulty
        lsr
        ora     DMTMP
        sta     DMTMP
        lda     INPT4           ; trigger, already in bit 7
        and     #$80
        ora     DMTMP
        sta     DMLOC0

; The checksum, at the same instant and not a moment later.
;
; A TAIL CALL, and it is not a micro-optimisation. The stack on this console is
; the top six bytes of the same 128 that hold the game, and the chain
; DMMIXV -> DMCAP -> DMCRC -> DMCRCR is four levels: eight bytes against six
; available, running into DMTMP and then the last byte of the sixth playfield
; stream. An overrun there does not crash -- it corrupts the track, slowly, and
; only in a match. DMCRC stores DMCRCV itself and returns to DMMIXV, which
; removes a level for nothing.
        jmp     DMCRC
DMCAP9:
        rts
