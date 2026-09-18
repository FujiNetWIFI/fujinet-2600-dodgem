; dmmix.inc -- fill the synthetic controller, and step the sim clock.
;
; The twenty-four patched read sites do not read a console port any more; they
; read DMSWA, DMSWB, DMTR4 and DMTR5. This is the one place those are written,
; and `make inputs` is the gate that says so.
;
; TWO ENTRY POINTS, ONE PER BAND, AND THEY DO DIFFERENT AMOUNTS OF WORK.
; DMMIXV is in dmmixv.inc, carried only by the bank that runs it.
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
; MIXED IN PORT SPACE, and that is the whole reason the twenty-four patches are
; one-instruction swaps.
;
; The host's stick always lands in bits 7-4 and the guest's always in bits 3-0,
; on BOTH consoles. The roles are not baked into the nibbles: $98 bit 7 already
; says who is dodging this round and who is driving the chase car, LF4F2 flips
; it at every round end, and the eight turn-decision sites already read the
; right nibble for whichever it is. Tennis's PORTING.md 2.4 is the same shape
; -- a role in port space and a court in index space, and mixing in the wrong
; one means each player driving the other's car while every coordinate agrees.
;
; The LOCAL half is not the live stick. It is the byte captured d ticks ago
; (DMLOC2 at d = 2), so this console applies its own input exactly as late as
; its peer's -- symmetric, and the only arrangement in which both machines run
; the same simulation.
DMNETIN:
        jsr     DMREMOTE        ; A = the peer's wire byte for this tick,
        bcc     DMNETST         ;   carry clear if it has not arrived

        sta     DMTMP           ; the peer's byte
        lda     DMENT
        and     #DME_ROLE
        bne     DMNETG

; ---- host: our stick is the left port, the peer's is the right ----
        lda     DMLOC2
        asl
        asl
        asl
        asl                     ; our nibble into bits 7-4
        sta     DMSWA
        lda     DMTMP
        and     #IW_STIK
        ora     DMSWA
        sta     DMSWA
        lda     DMLOC2          ; our trigger drives INPT4, the left port's
        and     #IW_TRIG
        sta     DMTR4
        lda     DMTMP
        and     #IW_TRIG
        sta     DMTR5
        jmp     DMNETSW

; ---- guest: the other way round, and nothing else changes ----
DMNETG:
        lda     DMTMP
        asl
        asl
        asl
        asl
        sta     DMSWA
        lda     DMLOC2
        and     #IW_STIK
        ora     DMSWA
        sta     DMSWA
        lda     DMTMP
        and     #IW_TRIG
        sta     DMTR4
        lda     DMLOC2
        and     #IW_TRIG
        sta     DMTR5

; ---- the console switches ----
;
; RESET and SELECT are ANDed on the wire, so either player may press either and
; both machines act on it at the same tick -- Dragster's arrangement. Both
; difficulty switches are networked, because $F05C reads one to pick the
; starting layout and $F540 reads the other for the chase car.
;
; BLACK AND WHITE IS NOT HERE, and its absence is deliberate. It is a local
; preference: each player keeps their own setting, it never reaches the wire,
; and $F0F5 reads the live port for it. Putting it on the wire would make one
; player's television decide the other's.
DMNETSW:
        lda     DMLOC2
        and     DMTMP           ; RESET and SELECT: pressed if EITHER pressed,
        and     #IW_SEL|IW_RST  ;   and both are active low, so AND is OR
        sta     DMSWB
        lda     DMLOC2
        and     #IW_DIFF        ; the host's difficulty -> SWCHB bit 7
        ora     DMSWB
        sta     DMSWB
        lda     DMTMP
        and     #IW_DIFF        ; the guest's -> bit 6
        lsr
        ora     DMSWB
        sta     DMSWB
        lda     SWCHB           ; ...and B/W, live and local
        and     #$08
        ora     DMSWB
        sta     DMSWB
        rts

; ---- the peer is not here yet: stall, and leave the shadows alone ----
;
; The shadows keep last tick's values, which is what a stalled frame wants:
; the picture is drawn from them and a stalled frame should look like the one
; before it, not like a console with its stick released.
DMNETST:
        lda     #0
        sta     DMADV
        rts

; ---------------------------------------------------------------------------
; DMREMOTE -- the peer's wire byte for the tick about to run.
;
; The window holds three ticks, newest first: DMRIN0 is DMRWAT, DMRIN1 is
; DMRWAT-1, DMRIN2 is DMRWAT-2. Combat's PORTING.md 4.24 is why it is three
; and not one -- a lockstep transport that sends exactly one tick per packet is
; betting it never misses a beat, and it will.
;
; Carry set and A = the byte if the tick we want is in the window; carry clear
; if the peer has not got there yet, or is so far ahead that the tick we want
; has already fallen out of the back of it.
; ---------------------------------------------------------------------------
DMREMOTE:
        lda     DMRWAT
        sec
        sbc     DMTICK          ; how far ahead of us the peer is
        bcc     DMREM9          ; behind us: nothing to apply
        cmp     #DMWIN
        bcs     DMREM9          ; further ahead than the window reaches
        tax
        lda     DMRIN0,x
        sec
        rts
DMREM9:
        clc
        rts
