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

; ---------------------------------------------------------------------------
; THE REPAIR, PRESSED INTO THE WIRE BYTE.
;
; dmnet.inc arms DME_RSY when the peer's checksum for a tick we have also
; sampled disagrees with ours. This is where it is acted on, and WHERE is the
; whole design: the repair is a synthetic RESET written into this console's own
; wire byte, so it is ANDed with the peer's on the way through and delivered
; through the delay ring exactly like a real press.
;
; That is what makes both consoles act on it at the SAME TICK. A repair applied
; locally and immediately would be a third state -- neither console's -- and
; two machines repairing at different ticks is a desync with extra steps.
;
; RESET IS ACTIVE LOW, so clearing the bit IS the press. Combat's PORTING.md
; 4.26 had to use a RESET because its tank positions were not in RAM at all;
; here it is used because Dodge 'Em's own RESET path already re-seeds every
; cell the simulation has -- LFC41, LF032, LF506 -- which is a better repair
; than anything this netcode could push across the wire in eight-byte records.
;
; One-shot, in two instructions: EOR against the byte that still holds the bit
; clears exactly it and nothing else.
        lda     DMENT
        and     #DME_RSY
        beq     DMCAPR
        eor     DMENT
        sta     DMENT
        lda     DMLOC0
        and     #$FF-IW_RST
        sta     DMLOC0
DMCAPR:

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
