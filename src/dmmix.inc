; dmmix.inc -- fill the synthetic controller, and step the sim clock.
;
; The twenty-four patched read sites do not read a console port any more; they
; read DMSWA, DMSWB, DMTR4 and DMTR5. This is the one place those are written,
; and `make inputs` is the gate that says so.
;
; TWO ENTRY POINTS, ONE PER BAND, AND THEY DO DIFFERENT AMOUNTS OF WORK.
;
; The four shadows are BAND-LOCAL -- they live in cells the game owns and does
; not touch across a band, because there were no other cells to have
; (dmdefs.inc) -- so they do not survive the kernel and have to be rebuilt on
; the far side of it. That is why the derivation runs twice.
;
; But the SIM CLOCK must step exactly ONCE a frame, and a quantity stepped
; twice is not a clock. So the stepping, the tick boundary and the capture all
; belong to the vblank call alone; the overscan call re-derives the shadows
; from state that has already been decided and adds nothing of its own.
;
; Both derivations therefore come from the same bytes and cannot disagree,
; which is what makes the split safe rather than merely convenient.
;
; Preserves Y: the bank dispatcher still needs it. Called from inside each
; band's timed window, never before the timer is armed -- work in front of an
; arm lengthens the frame, and `make frames` measured exactly that.

; ---------------------------------------------------------------------------
; DMMIXV -- the vblank call. Steps the clock, then derives.
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; DMMIXO -- the overscan call. Derives only.
; ---------------------------------------------------------------------------
DMMIXO:
        ; fall through

; ---------------------------------------------------------------------------
; DMDERIV -- the synthetic controller, from whatever the clock decided.
; ---------------------------------------------------------------------------
DMDERIV:
        lda     DMENT
        and     #DME_NET
        bne     DMNETIN

DMLOCAL:
; ---- not in a match, so the console drives both cars ----
;
; Straight through, with the hardware's own active-low sense intact. Nothing is
; normalised and nothing is decoded: the eight turn-decision sites each pick
; their own bits out of SWCHA -- one pair does LSR/LSR/LSR/BCC on the right
; port's, another BPL/ASL/BMI on the left's -- and they all work unchanged as
; long as what they read is a faithful SWCHA. Mixing in PORT space and letting
; the game's own `BIT $98` decide who is driving what is the whole reason the
; twenty-four patches are one-instruction swaps.
;
; THIS IS THE PLAIN PATH, and the networked one is in front of it rather than
; around it. Combat's PORTING.md 4.13: a cartridge with no server is still a
; Dodge 'Em cartridge, and `make det` depends on this path being ordinary.
        lda     SWCHA
        sta     DMSWA
        lda     SWCHB
        sta     DMSWB
        lda     INPT4
        sta     DMTR4
        lda     INPT5
        sta     DMTR5
        rts

; ---- in a match: both consoles derive both cars from the two wire bytes ----
;
; Not written yet. When it is, it mixes the delayed local wire byte (DMLOC0-2) with the
; peer's, in PORT space: the host's stick always in bits 7-4 and the guest's
; always in bits 3-0, on both consoles. The roles are not baked into the
; nibbles -- $98 bit 7 already swaps which port drives the dodger and which
; the chaser, every round, and letting the game's own logic do that is what
; keeps the twenty-four patches one-instruction swaps.
DMNETIN:
        jmp     DMLOCAL         ; until the transport lands, play it local
