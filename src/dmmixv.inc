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

; THE SIM ADVANCES UNLESS SOMETHING SAYS OTHERWISE, and the default matters
; more than it looks. DMADV lives in $C2, which the cold clear sweeps to zero
; along with the rest of the page -- so a gate that only ever CLEARS this cell
; would leave the console stalled forever from power-on, drawing a perfect
; still picture of a game that never starts. Set it every frame; let the
; lockstep gate clear it.
DMMIXV:
        lda     #$FF
        sta     DMADV

; ---------------------------------------------------------------------------
; A TICK EITHER RUNS OR IT DOES NOT. IT DOES NOT RUN PARTLY.
;
; A tick is DMK frames and the sim advances once per FRAME, so the thing that
; has to be identical on both consoles is the number of ADVANCED frames. The
; first version of this stepped the phase every frame and let DMDERIV clear
; DMADV whenever the peer's byte was missing -- so a record landing part way
; through a tick stalled the frames before it and advanced the frames after it,
; and that tick got fewer logic steps here than it got there. Nothing brings
; two consoles back from that. Measured: 1171 advanced frames against 1183 over
; the same 1200, both consoles sitting on tick 43. PORTING.md 15.2.
;
; So the decision is made ONCE, at the boundary, and on a stall THE PHASE IS
; NOT STEPPED -- the next frame is the same boundary again, which is what
; retrying a tick means. Tennis's PORTING.md says it in one line and this port
; had to measure it: "the frame counters are not ticked either, which is what
; keeps $84 a count of simulated frames on both consoles however differently
; they stalled."
        lda     DMENT
        and     #DME_NET
        beq     DMMVPHI         ; not in a match: the clock just runs
; THE PHASE IS TESTED BEFORE IT IS STEPPED, so the question is not "is this the
; boundary" but "is the NEXT step the boundary". DMCAP asks DMTICKB after DMPHI
; has run, so its boundary is the frame the phase steps INTO 0 -- and a test
; here for phase 0 fires one frame later than the tick it is deciding about.
        lda     DMENT
        and     #DME_PHI
        cmp     #DME_PHI        ; phase 3: the next step lands on the boundary
        bne     DMMVPHI         ; mid-tick: this tick already began, so it runs

; The boundary. The same test DMREMOTE will make once DMTICK has been stepped,
; made here against the tick ABOUT to run -- so a boundary that passes cannot
; be followed by a DMREMOTE that fails.
        lda     DMRWAT
        sec
        sbc     DMTICK          ; how far ahead of us the peer is
        beq     DMMVSTL         ; level: the tick about to run is not here yet
        bmi     DMMVSTL         ; behind us -- SIGNED, see DMREMOTE
        cmp     #DMWIN+1
        bcs     DMMVSTL         ; so far ahead it has fallen out of the window
DMMVPHI:
        jsr     DMPHI           ; step the frame-in-tick counter

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

; ---------------------------------------------------------------------------
; THE DIFFICULTY PAIR, COMPUTED IN THE BAND THAT HAS ROOM FOR IT.
;
; SWCHB bit 6 is P0's difficulty and bit 7 is P1's. The host drives the left
; port and IS P0; the guest is P1. But DMLOC2 is whichever of the two THIS
; console happens to be, so the derivation is role-dependent -- and a role-blind
; one hands the two machines different bytes the moment their switches differ.
; Two MAMEs with identical defaults never differ, which is exactly why that sat
; unseen behind a green rig. $F08D reads bit 7 to pick the starting layout, so
; this decides the track both players drive.
;
; It is here, and not in DMDERIV, for a reason worth writing down: DMDERIV is
; carried by BOTH bands, and the overscan bank had nine bytes of room left. The
; vblank bank has 786. So the role-aware half runs once a frame here, the
; result keeps in DMDIFF -- $B4, netcode-owned, so the kernel cannot touch it --
; and both bands just OR it in. The per-band derivation came out SMALLER than
; the broken one it replaced.
;
; On a stall DMDIFF keeps its last value, which is what the shadows do too.
        jsr     DMREMOTE
        bcc     DMNOCAP         ; no peer byte this tick: keep the last pair
        sta     DMTMP
        lda     DMENT
        and     #DME_ROLE
        bne     DMDIFG

; Host console: we are P0 (SWCHB bit 6), the peer is P1 (bit 7). Each arm
; overwrites DMTMP only after reading it, so the pair needs no second scratch
; -- and there is no second scratch to have.
        lda     DMTMP           ; the peer, P1
        and     #IW_DIFF
        asl                     ; -> bit 7
        sta     DMTMP
        lda     DMLOC2          ; us, P0
        and     #IW_DIFF        ; -> bit 6, already in place
        ora     DMTMP
        jmp     DMDIFP

DMDIFG:
; Guest console: the peer is P0, we are P1.
        lda     DMTMP           ; the peer, P0
        and     #IW_DIFF        ; -> bit 6, already in place
        sta     DMTMP
        lda     DMLOC2          ; us, P1
        and     #IW_DIFF
        asl                     ; -> bit 7
        ora     DMTMP

DMDIFP:
; ...and into the plane, THROUGH THE BLIT PORT, because $1800-$1AFF is
; cart-to-console and a store there reaches nothing at all. It fires only when
; the pair has actually CHANGED -- which is when somebody flips a switch, so in
; practice never. dmpoke.inc's DMFIRE does the generation wait.
        cmp     DMDIFF
        beq     DMDIF9
        sta     FNRSEL+FH_BSL
        lda     #DMDIFFO&$FF
        sta     FNRSEL+FH_BDL
        lda     #DMDIFFO>>8
        sta     FNRSEL+FH_BDH
        jsr     DMFIRE
DMDIF9:
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

; ---- the tick has not arrived: hold everything where it is ----
;
; No phase step, so the next frame is this boundary again. No capture, so the
; local ring keeps its shape. DMDERIV still runs, because the shadows are
; band-local and the picture is drawn from them -- it will find the same bytes
; it found last frame and rebuild the same values.
DMMVSTL:
        lda     #0
        sta     DMADV
        jmp     DMDERIV

