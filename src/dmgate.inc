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
; DMOVGATE -- the overscan chain's gate. Patched in at $F42E.
;
; It owes the game the instruction it displaced and the three that follow it,
; because $F430 is in the middle of a run with no label to return to. Four
; instructions duplicated is the price of gating the countdowns; the
; alternative was a gate that let them run.
; ---------------------------------------------------------------------------
DMOVGATE:
        lda     DMADV
        beq     DMOVSKIP
        lda     $86             ; the displaced instruction...
        and     #$3F            ; ...and its run, re-laid rather than jumped
        beq     DMOVG1          ;   back into
        dec     $86
        jmp     LF4EA
DMOVG1:
        jmp     LF439

DMOVSKIP:
        jmp     LF4EA           ; straight to the band's spin: no countdowns,
                                ;   no movement, no swap, no counters
