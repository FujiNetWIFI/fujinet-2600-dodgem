; dmmixv.inc -- the VBLANK call: step the clock, then derive.
;
; Split from dmmix.inc because only ONE bank runs it. The four shadows are
; band-local and have to be rebuilt on both sides of the kernel, so the
; derivation is carried by two banks -- but a clock stepped twice a frame is
; not a clock, so the stepping, the tick boundary and the capture belong to the
; vblank call alone.
;
; Carrying this in both banks is not merely wasteful: it pushed the overscan
; bank's packed code into the pinned table span at the top of the window, which
; p2bin reports as an overlap and then resolves by letting the later write win.

DMMIXV:
        jsr     DMPHI           ; step the frame-in-tick counter

; THE SIM ADVANCES UNLESS SOMETHING SAYS OTHERWISE, and the default matters
; more than it looks. DMADV lives in $C0, which the cold clear sweeps to zero
; along with the rest of the page -- so a gate that only ever CLEARS this cell
; would leave the console stalled forever from power-on, drawing a perfect
; still picture of a game that never starts. Set it every frame; let the
; lockstep gate clear it.
        lda     #$FF
        sta     DMADV

; The tick boundary, IN A MATCH ONLY.
;
; Not because it would be wrong to capture locally -- it would be harmless --
; but because it reads the console's own ports, and the un-networked path has
; to stay exactly what it was for `make det` to mean anything. Gating here
; keeps the two paths from sharing anything but the derivation.
        lda     DMENT
        and     #DME_NET
        beq     DMNOCAP
        jsr     DMCAP
DMNOCAP:

        IF      DMSTALLT
; THE INTERCEPTION PROOF (`make stall`). Built only when asked for.
;
; The stall is the primitive the whole transport rests on -- a console waits
; for a peer by drawing a frame with the logic chain skipped -- and an untested
; primitive under a transport is a bug with somewhere to hide. So this build
; stalls every other TICK, unconditionally and with no network involved, and
; emu/stall.lua requires the simulation to advance at half speed while the
; picture keeps its 262 lines.
;
; It gates on the tick phase rather than the frame counter so that a stall
; covers a whole tick: stalling one frame in eight would be absorbed by the
; other three frames of the tick and prove nothing.
        lda     DMENT
        and     #$80            ; bit 7 of the phase: alternate ticks
        beq     DMSTNO
        lda     #0
        sta     DMADV
DMSTNO:
        ENDIF

        jmp     DMDERIV

