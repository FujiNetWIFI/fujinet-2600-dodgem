; dmgate.inc -- the stall.
;
; A stall is a frame that runs NORMALLY with the game-logic chain skipped. The
; picture is still drawn, the sound still plays, the console still reads its
; sticks -- only the simulation does not move. It is how a console waits for a
; peer that is a tick behind without the player seeing anything worse than a
; pause, and it is free on this game because the picture is regenerated from
; state every frame.
;
; TWO CHAINS, because Dodge 'Em advances its simulation in two places:
;
;   $F228  JSR LF859   the dot-and-scoring engine, in the vblank band
;   $F4C6  the movement chain, in overscan: LF5BF turns the cars, LF5A0 swaps
;          the players' saved blocks, and $F4E0-$F4E9 step the frame counters
;
; THE COUNTERS ARE INSIDE THE GATE, not outside it. Video Olympics' PORTING.md
; 3.16 is the rule -- everything left ungated becomes a function of the local
; stall pattern, and the stall pattern is the one thing two consoles differ in
; by design, because absorbing it is what lockstep is FOR. Its frame counter
; and sound countdown both had to move behind the gate. Here $82 and $97 are
; stepped at $F4E0-$F4E8 and they go behind it too.
;
; Not in a match, DMADV is always nonzero and neither gate ever fires, which is
; what lets `make det` prove this build is the 1980 cartridge.

; ---------------------------------------------------------------------------
; DMOVGATE -- the overscan chain's gate. Patched in at $F4C6.
;
; It owes the game the instruction it displaced: `LDA $81`, which $F4C8's
; `AND #$7F` consumes. Doing that here rather than duplicating $F4C8 keeps the
; chain's own flags exactly as they were.
; ---------------------------------------------------------------------------
DMOVGATE:
        lda     DMADV
        beq     DMOVSKIP
        lda     $81             ; the displaced instruction
        jmp     LF4C6+2

DMOVSKIP:
        jmp     LF4EA           ; straight to the band's spin: no movement, no
                                ;   swap, no counters
