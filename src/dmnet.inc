; dmnet.inc -- the non-blocking network machine.
;
; A transaction blocks for up to five seconds. The sim has to keep running
; while the transport works, so the transport is a state machine of bounded
; micro-steps, stepped from a loop that re-reads INTIM before every one -- it
; cannot overrun the frame by construction, because there is no budget to get
; wrong.
;
; IT LIVES IN G0 AND IS STEPPED AT $F243, the last instruction of the vblank
; band, immediately before the switch to the kernel bank. That position is not
; a convenience: the kernel bank is entered AT ITS SPIN ($F244, `LDA INTIM /
; BNE`), so whatever the loop leaves of the band is waited out by code that was
; going to wait anyway. Tennis's PORTING.md 2.2 rule -- put the work on the
; running side of the wait -- lands here as a seam rather than as a hook.
;
; THE MACHINE FREE-RUNS. It is never told a tick has passed and never needs to
; be: it sends whatever tick the sim is on when the WRITE comes round, and a
; duplicate is idempotent. A machine running slower than the tick rate simply
; causes a stall, which is exactly the right behaviour.

; ---------------------------------------------------------------------------
; DMNSTEP -- one bounded step.
;
; Dispatched through the RTS trick: 26 cycles flat. A CMP/BEQ chain would be
; sixty at worst and, worse, VARIABLE -- and the gate's arithmetic is stated as
; a worst case, so a constant one is worth having.
DMNSTEP:
        ldx     DMNST
        lda     DMJT+1,x
        pha
        lda     DMJT,x
        pha
        rts

; addr-1, because RTS increments what it pulls.
DMJT:
        DW      DMSIDLE-1
        DW      DMSWISS-1
        DW      DMSWACK-1
        DW      DMSSISS-1
        DW      DMSSACK-1
        DW      DMSRISS-1
        DW      DMSRACK-1
        DW      DMSCONS-1
        DW      DMSFAIL-1

DMSIDLE:
        rts

; ---------------------------------------------------------------------------
; DMLNCH -- commit a transaction and go to state A.
;
; THE NEXT SEQUENCE NUMBER COMES FROM THE CARTRIDGE'S OWN PERSISTED ACKSEQ + 1,
; never a counter in RAM. This connector carries no reset line: the RESET
; switch restarts the 6507 and leaves the cartridge running, so a program-local
; counter would restart at 1, collide with a sequence already answered, and the
; transaction would be dropped in silence.
DMLNCH:
        sta     DMNST
        lda     FNACKS
        clc
        adc     #1
        bne     DMLN1
        lda     #1              ; 0 is reserved as "never used"
DMLN1:  sta     DMSEQ
        ldx     #FR_SEQ
        jmp     FNRW            ; the single commit that launches it

; DMNACK -- has the cartridge answered? Z set if it has.
;
; ACKSEQ is published LAST, after the reply, its length and the error code are
; all in place, so a match means everything behind it is already readable.
DMNACK:
        lda     FNACKS
        cmp     DMSEQ
        rts

; ---------------------------------------------------------------------------
; WRITE -- our record, stamped d ticks ahead.
DMSWISS:
        lda     #NETDEV
        ldx     #FR_DEV
        jsr     FNRW
        lda     #NCWRITE
        ldx     #FR_CMD
        jsr     FNRW
        lda     #1
        ldx     #FR_NPAR
        jsr     FNRW
        lda     #0
        ldx     #FR_DRST
        jsr     FNRW
; ONE parameter of TWO bytes -- the length -- and not two of one. The stream is
; NPARAM x { size byte, then that many little-endian value bytes }, so a length
; sent as two one-byte parameters is a different request entirely.
        lda     #2
        sta     FNTX
        lda     #IR_LEN
        sta     FNTX
        lda     #0
        sta     FNTX
; The frame: len, type, then six bytes of payload. Eight on the wire, and eight
; is a power of two on purpose -- see DMSSACK.
        lda     #IR_LEN-1
        sta     FNTX
        lda     #WT_INPUT
        sta     FNTX
; b0 -- the tick the window ENDS at, d ticks ahead of the one being simulated.
;
; THE CHECK BYTE IS COMPUTED FIRST AND KEPT IN A REGISTER. The obvious shape --
; store a byte, fold it into a running total in a cell, repeat -- costs an LDA
; and an STA per byte and, worse, costs a zero-page CELL, in a port that has
; one spare. Everything folded here is already in a known cell, so it can be
; read twice instead: once to accumulate and once to send.
        lda     DMTICK
        clc
        adc     #DMD
        tay                     ; Y = the stamped tick, wanted twice
        sty     FNTX
        tya
        eor     #IR_SEED
        eor     DMLOC0
        eor     DMLOC1
        eor     DMLOC2
        eor     DMCRCV
        tax                     ; X = the check byte, over the whole frame
;
; b1, b2, b3 -- A WINDOW OF THREE TICKS, NEWEST FIRST, NOT ONE BYTE.
;
; The transport is not locked to the tick and cannot be. It free-runs a
; WRITE/STATUS/READ cycle and sends whatever tick the sim is on when the WRITE
; comes round; a cycle that takes longer than one tick means the sim advanced
; twice between two WRITEs and A TICK'S RECORD WAS NEVER SENT AT ALL. You
; cannot send N ticks in fewer than N writes, so the answer is not to try:
; batch. Combat's PORTING.md 4.24 is the account of finding that out the other
; way round, and of how long it stayed invisible -- in attract every byte on
; the wire is IDLE, so a stale IDLE and a fresh one are the same byte.
;
; The local window is a three-byte shift register, so this is just three
; stores. DMLOC0 is the newest.
        lda     DMLOC0
        sta     FNTX
        lda     DMLOC1
        sta     FNTX
        lda     DMLOC2
        sta     FNTX
; b4 -- the checksum SAMPLED AT THE LAST TICK BOUNDARY, not computed here. The
; transport free-runs and the sim moves every frame, so a checksum taken at
; this instant is a different quantity on the two consoles and disagrees for no
; reason at all (Combat 4.5).
        lda     DMCRCV
        sta     FNTX
        stx     FNTX            ; b5 -- the check byte
        lda     #NS_WACK
        jmp     DMLNCH

DMSWACK:
        jsr     DMNACK
        beq     DMWA1
        rts
DMWA1:  lda     FNERR
        bne     DMFJ1
        lda     #NS_SISS
        sta     DMNST
        rts

; A trampoline per state, because DMSFAIL is further than a branch reaches from
; most of them. Each sits immediately after an rts, so the straight line
; through the state above cannot run into it.
DMFJ1:  jmp     DMSFAIL

; ---------------------------------------------------------------------------
; STATUS -- how many bytes are waiting.
;
; STATUS BEFORE READ IS NOT OPTIONAL, and the reason is worse than it sounds:
; NParser::read resizes its buffer to the length asked for and then copies that
; many bytes out of a receive buffer that may be shorter. That is not an error
; path, it is undefined behaviour returning plausible garbage. Never ask for
; more than the last STATUS reported.
DMSSISS:
        lda     #NETDEV
        ldx     #FR_DEV
        jsr     FNRW
        lda     #NCSTAT
        ldx     #FR_CMD
        jsr     FNRW
        lda     #2
        ldx     #FR_NPAR
        jsr     FNRW
        lda     #0
        ldx     #FR_DRST
        jsr     FNRW
; THE PARAMETERS ARE (1, 0) AND THEY GO THROUGH FNPB, which emits each one as a
; SIZE byte and then its value. Written raw, `01 00 01 00` looks like "two
; one-byte params, 1,0,1,0" -- and it is not: it is two parameters whose values
; are BOTH ZERO, because the 1s in that phrase are the size bytes FNPB
; supplies. NET STATUS refuses unit 0, fujinet-pc answers dlen:-1, no record is
; ever read, and two consoles stall each other into a match that restarts every
; few seconds with zero CRC mismatches -- because everything that did run, ran
; in lockstep. Tennis lost a day to it.
        lda     #1
        jsr     FNPB
        lda     #0
        jsr     FNPB
        lda     #NS_SACK
        jmp     DMLNCH

DMSSACK:
        jsr     DMNACK
        beq     DMSA1
        rts
DMSA1:  lda     FNERR
        bne     DMFJ2
; The fourth status byte is nDevStatus_t and SUCCESS is 1, not 0. It is the
; only place a transport error is visible: a dead socket reports a perfectly
; plausible zero bytes waiting.
        lda     FNRPLY+NSDEVST
        cmp     #1
        bne     DMFJ2
; THE SETTLE RULE, AND WHY THIS PORT DOES NOT NEED THE FAMILY'S. Battleship
; polls until two consecutive readings agree, because an HTTP body arrives in
; pieces and its length is not known in advance. Here every frame is exactly
; eight bytes, so `avail AND $F8` reads only WHOLE frames and a partial one is
; left for next time. The misframing that rule guards against is structurally
; unreachable, and the second STATUS round trip would cost a third of a tick.
; A deliberate departure, not an oversight.
        lda     FNRPLY+NSAVHI
        bne     DMSA2           ; 256 or more waiting: take a capped bite
        lda     FNRPLY+NSAVLO
        and     #IR_MASK
        beq     DMSA3           ; nothing whole yet
        sta     DMRDN
        lda     #NS_RISS
        sta     DMNST
        rts
DMSA2:  lda     #$F8            ; 248 bytes, 31 records, well inside the window
        sta     DMRDN
        lda     #NS_RISS
        sta     DMNST
        rts
DMSA3:  lda     #NS_WISS        ; nothing to read: send the next record
        sta     DMNST
        rts

DMFJ2:  jmp     DMSFAIL

; ---------------------------------------------------------------------------
; READ -- exactly the whole frames STATUS reported.
DMSRISS:
        lda     #NETDEV
        ldx     #FR_DEV
        jsr     FNRW
        lda     #NCREAD
        ldx     #FR_CMD
        jsr     FNRW
        lda     #1
        ldx     #FR_NPAR
        jsr     FNRW
        lda     #0
        ldx     #FR_DRST
        jsr     FNRW
        lda     #2
        sta     FNTX
        lda     DMRDN
        sta     FNTX
        lda     #0
        sta     FNTX
        lda     #NS_RACK
        jmp     DMLNCH

DMSRACK:
        jsr     DMNACK
        beq     DMRA1
        rts
DMRA1:  lda     FNERR
        bne     DMFJ3
; CAPTURE THE LENGTH NOW. FNRXLO belongs to the most recent transaction and the
; next one replaces it -- and the next one is always zero, because a WRITE
; returns nothing.
        lda     FNRXLO
        lsr     a
        lsr     a
        lsr     a               ; bytes to records; the frame size is 8
        sta     DMRDN
        lda     #NS_CONS
        sta     DMNST
        rts

DMFJ3:  jmp     DMSFAIL

; ---------------------------------------------------------------------------
; CONSUME -- one record a step, backwards.
;
; Backwards so DMRDN is both the counter and the cursor: the record at index n
; starts at n*8. Read IN PLACE out of the cartridge's reply window; nothing is
; copied to console RAM but the window itself, because there is no RAM to copy
; into -- the 128 bytes are Dodge 'Em's, every one.
DMSCONS:
        lda     DMRDN
        bne     DMCO1
        lda     #NS_WISS
        sta     DMNST
        rts
DMCO1:  dec     DMRDN
        lda     DMRDN
        asl     a
        asl     a
        asl     a
        tay
        lda     FNRPLY+1,y      ; the type
        cmp     #WT_INPUT
        beq     DMCO2
        cmp     #WT_LEFT
        bne     DMCO9
; The peer left. Saturate the stall watchdog as well as recording the reason:
; the gate gives up when that counter tops out, and setting it here is what
; makes a CLEAN leave instant rather than making the player wait out the same
; second an unplugged console would cost.
        lda     #$F0|FNEPEER
        sta     DMERR
        rts
DMCO2:
; The check byte, over every byte of the frame that carries anything. With
; whole-frame reads a misframe cannot happen, so this can only catch a
; genuinely corrupt record -- which is the point: it is the difference between
; "the peer's car moved oddly" and a counter that says so.
        lda     FNRPLY+2,y
        eor     FNRPLY+3,y
        eor     FNRPLY+4,y
        eor     FNRPLY+5,y
        eor     FNRPLY+6,y
        eor     #IR_SEED
        cmp     FNRPLY+7,y
        bne     DMCO9           ; a bad record is dropped, never acted on

; NEWER RECORDS ONLY, and then the whole window at once.
;
; This is where this port is simpler than its siblings. They keep an eight-slot
; ring indexed by tick and write each of the three bytes into the slot for its
; own tick, so a record that never arrived is filled in by the next one. Here
; the window IS the record's window: DMRIN0-2 are newest-first for DMRWAT, and
; that is exactly the shape of b1,b2,b3 for b0. So a newer record replaces all
; three and carries the same fill-in for free, and a stale one is dropped
; whole rather than being allowed to pull the watermark back.
;
; Signed, because the tick is eight bits and wraps.
        lda     FNRPLY+2,y
        sec
        sbc     DMRWAT
        beq     DMCO3           ; the same tick again: still worth the CRC
        bmi     DMCO9           ; older: drop it
DMCO3:
        lda     FNRPLY+3,y
        sta     DMRIN0
        lda     FNRPLY+4,y
        sta     DMRIN1
        lda     FNRPLY+5,y
        sta     DMRIN2
        lda     FNRPLY+2,y
        sta     DMRWAT

; ---------------------------------------------------------------------------
; DESYNC DETECTION, ON THE CONSOLE ITSELF.
;
; The relay has always reported mismatches, but a log on another machine cannot
; repair anything. The record carries the sender's checksum, sampled at ITS
; last tick boundary -- which is the boundary of tick (b0 - d), because the
; record is stamped d ticks ahead. So when that tick is the one WE are on, the
; peer's checksum and our DMCRCV are samples of the same instant and must be
; equal.
;
; Only then. DMCRCV is one cell holding the current tick's sample and there is
; no room for a history, so a record whose tick does not line up is simply not
; compared. That costs nothing: a desync is persistent, and the ticks line up
; within a few of them.
;
; A false positive is impossible -- a difference here IS a difference in the
; simulation -- and a corrupt record was already dropped by the check byte.
        lda     FNRPLY+2,y
        sec
        sbc     #DMD
        cmp     DMTICK
        bne     DMCO9           ; not comparable this time; there will be more
        lda     DMENT
        and     #DME_RSY
        bne     DMCO9           ; already armed. Records from before the repair
                                ;   are still in flight and must not arm it
                                ;   again on their way past.
        lda     FNRPLY+6,y
        cmp     DMCRCV
        beq     DMCO9
        lda     DMENT
        ora     #DME_RSY        ; DMCAP presses RESET on the wire
        sta     DMENT
DMCO9:  rts

; ---------------------------------------------------------------------------
DMSFAIL:
        lda     DMERR
        and     #$F0
        ora     #FNEBAD
        sta     DMERR
        lda     #NS_WISS
        sta     DMNST
        rts

; ---------------------------------------------------------------------------
; DMWAIT -- step the machine for whatever is left of the vblank band.
;
; Called at $F243, the last instruction of the band, immediately before the
; switch to the kernel bank -- whose entry IS the spin that waits the band out.
; So everything this loop does not use is waited out by code that was going to
; wait anyway, and the frame is unchanged. `make frames` is the gate.
;
; THE LOOP CANNOT OVERRUN BY CONSTRUCTION. INTIM is re-read before every step
; and the loop stops when the slack is gone; there is no budget to get wrong.
; TIM64T decrements every 64 cycles, so DMGATE = 8 guarantees 512 cycles remain
; against a worst step of about 310.
DMWAIT:
        lda     DMENT
        and     #DME_NET
        beq     DMWAIT9         ; no match: nothing to step
DMWLOOP:
        lda     INTIM
        cmp     #DMGATE
        bcc     DMWAIT9         ; THROUGH THE CARRY: INTIM is unsigned, and a
                                ;   sign test on an unsigned quantity is how
                                ;   the Channel F port lost a day
        jsr     DMNSTEP
        jmp     DMWLOOP
DMWAIT9:
        rts
