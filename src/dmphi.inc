; dmphi.inc -- the frame-in-tick phase.
;
; The sim clock is a tick of DMK = 4 video frames, and this is what steps it.
;
; THE CELL THAT SAYS WHICH FRAME OF THE TICK THIS IS MUST LIVE SOMEWHERE THE
; GAME HAS NO INSTRUCTION THAT TOUCHES (Combat's PORTING.md 4.20). On this
; console that is a stronger requirement than it sounds: every cell this
; netcode owns was the game's yesterday, evicted into a cartridge text plane to
; make room. DMENT is the one byte that was never Dodge 'Em's at all.
;
; So the phase lives in its top two bits, and stepping it is an add that
; discards its own carry -- eight bytes, no branch, and nothing to get wrong
; at the wrap.
DMPHI:
        lda     DMENT
        clc
        adc     #$40            ; +1 in bits 6-7; the carry out of bit 7 is
        sta     DMENT           ;   dropped, which IS the modulo
        rts

; DMTICKB -- Z clear on the frame that begins a tick.
;
; The boundary is phase 0, so it is the state the counter has just wrapped
; INTO. Reading it as "bits 6-7 are zero" rather than counting separately
; means there is no second copy of the clock to disagree with the first.
DMTICKB:
        lda     DMENT
        and     #DME_PHI
        rts
