; dmdefs.inc -- equates only. Included BEFORE the ORG.
;
; Code goes in dmcore.inc and the bank bodies; nothing here emits a byte. The
; distinction is not tidiness: AS resolves IF in its FIRST PASS, and a file
; that mixes the two ends up assembling the transport at $0000, where every
; JSR becomes 20 00 00 and the build succeeds.
;
; ===========================================================================
; THE ZERO PAGE, WHICH IS THIS PORT'S WHOLE PROBLEM
; ===========================================================================
;
; Dodge 'Em uses all 128 bytes of the RIOT. Not nearly all -- all. `make zp`
; is the census and PORTING.md is the account:
;
;     $80-$AB   44   game variables
;     $AC-$B4    9   per-row dot bitmap        -> EVICTED, see below
;     $B5-$BB    7   player A's saved state
;     $BC-$C2    7   player B's saved state    -> EVICTED, see below
;     $C3-$F8   54   six playfield streams     (the kernel reads these; stays)
;     $F9        1   never touched by the game
;     $FA-$FF    6   stack, measured not assumed -- deepest JSR chain is 6
;
; 44 + 9 + 7 + 7 + 54 + 1 + 6 = 128, and one of those cells is free.
;
; So sixteen bytes of the GAME move into a cartridge text plane, which is the
; only memory this console can both write (FN_BLIT_POKE) and read back
; (`lda $1AE0,x`). What moved was chosen by how often it is written and who
; reads it, never by size:
;
;   $AC-$B4  read in VBLANK only, never by the kernel; written at four EOR
;            sites and only when a dot is actually eaten.
;   $BC-$C2  read in OVERSCAN only; written by LF5A0's swap, at a round end.
;
; The six playfield streams at $C3-$F8 are 54 bytes and would have been the
; easy choice. They are also what the KERNEL reads twice per scanline pair at
; exact cycle positions, so moving them would put a plane read in the tightest
; budget in the game to buy headroom nothing needs.
;
; ---------------------------------------------------------------------------
; PERSISTENT vs BAND-LOCAL, and why the difference is not pedantry
; ---------------------------------------------------------------------------
;
; A netcode cell is one of two things and they have completely different
; requirements:
;
;   PERSISTENT  must survive from one overscan band to the NEXT: the tick, the
;               sequence, the rings. It needs a cell the game never writes at
;               all, because anything the game writes in vblank or the kernel
;               lands squarely between two bands and wipes it.
;
;   BAND-LOCAL  is born and dies inside one band: the synthetic controller
;               shadows, rebuilt at the head of each band from the persistent
;               wire bytes. It only needs a cell the game does not touch
;               DURING that band.
;
; The first census this port ran reported nineteen cells "dead across the
; overscan band" and that looked like plenty. Twelve of them were $88-$93, the
; six score-digit pointers -- dead in overscan and rewritten every vblank, so
; useless for anything that has to outlive a frame. Ask which of the two you
; need before you count.
;
; ===========================================================================

; ---------------- persistent: the evicted $AC-$B4 and $BC-$C2 ----------------
;
; THE TWO WINDOWS ARE CONTIGUOUS, and that is a requirement rather than a
; tidiness: DMREMOTE reaches the peer's window with `lda DMRIN0,x`, so slot 2
; had better be DMRIN0+2. The first arrangement put DMRIN2 at $BC, across the
; gap between the two evicted blocks, and index 2 read player A's saved state
; instead. It assembled and it would have desynced on the first tick the peer
; ran two ahead. The assertions at the foot of this file are there so the next
; rearrangement cannot repeat it.
DMENT   EQU     $AC             ; entry mode, role, phase and the flags below
DMTICK  EQU     $AD             ; sim tick, low 8 bits
DMSEQ   EQU     $AE             ; the sequence we are waiting for
DMNST   EQU     $AF             ; the network machine's state
DMERR   EQU     $B0             ; low nibble last transport error, high nibble
                                ;   the stall watchdog, saturating at $F
DMCRCV  EQU     $B1             ; the sim checksum, SAMPLED AT A TICK BOUNDARY
                                ;   and never anywhere else -- a quantity
                                ;   sampled on the ticks that RAN is a fact
                                ;   about the local stall pattern, which is
                                ;   the one thing two consoles differ in by
                                ;   design (Combat 4.5)
DMRWAT  EQU     $B2             ; highest remote tick received

; DMRDN -- records left to consume, and the cursor into the reply window: the
; record at index n starts at n * IR_LEN. Live from DMSSACK through DMSCONS and
; dead during the WRITE, which is the only other state that wants a scratch
; cell -- but they are NOT union'd, because that claim is one restructuring
; away from being false and the transport's WRITE was restructured to keep its
; check byte in a register instead. One cell bought, one claim not made.
DMRDN   EQU     $B3

; $B4 is deliberately UNSPENT. A port whose zero page fits exactly has
; no room for the cell the next bug needs, and in this family there is always
; one more cell. Do not allocate these to make something fit; work out why it
; did not fit.
DMFREE1 EQU     $B4

; The peer's input window, newest first: DMRIN0 is tick DMRWAT, DMRIN1 is
; DMRWAT-1, DMRIN2 is DMRWAT-2. THREE, not one: a lockstep transport that sends
; exactly one tick per packet is betting it never misses a beat, and it will
; (Combat 4.24).
DMRIN0  EQU     $BC
DMRIN1  EQU     $BD
DMRIN2  EQU     $BE

; The local input ring, the same shape. d = 2, so the live slots are t, t-1 and
; t-2 and nothing older is ever wanted -- a three-byte shift rather than a ring
; indexed by tick, because a shift has no modulo to get off by one. DMLOC0 is
; also the wire byte for the tick being captured: it is the same quantity, and
; a separate copy would be a second place for the tick and its input to
; disagree (Combat 4.14).
DMLOC0  EQU     $BF
DMLOC1  EQU     $C0
DMLOC2  EQU     $C1

DMADV   EQU     $C2             ; nonzero: the sim advances this frame

; Scratch, dead between routines -- allocated out of the one cell below the
; stack that the game never writes, because the four cells free across both
; bands are all spent on the synthetic controller and there is no fifth.
DMTMP   EQU     $F9

; ---------------- the union: the session's transport cells ----------------
;
; The rings belong to a MATCH. The transaction setup cells belong to the boot
; bank's session -- HELLO, the appkeys, waiting for START -- which finishes
; before a match can start. The two sets are never live at the same time, so
; they share addresses.
;
; What makes that safe is a property of dmnet.inc and not of the schedule: the
; match-time network machine writes the cartridge's registers DIRECTLY and
; never calls FNBEG, so nothing during a match reads FNDEV, FNCMD or FNNPR.
; The siblings do the same and for the same reason. If a future net machine
; ever calls FNBEG, this union is the first thing that breaks and it will break
; as a desync rather than as a build error, so: do not.
FNDEV   EQU     DMRIN0          ; transaction setup, read by FNBEG
FNCMD   EQU     DMRIN1
FNNPR   EQU     DMRIN2
FNTMO   EQU     DMLOC0          ; timeout in ~0.6s quanta
FNCNT   EQU     DMLOC1          ; timeout quanta remaining
FNSEQ   EQU     DMSEQ           ; not a union: the sequence IS the same
                                ;   quantity in both phases

; ---------------- band-local: the synthetic controller ----------------
;
; Rebuilt twice a frame by DMMIX -- once at the head of the vblank band and
; once at the head of the overscan band -- from the SAME persistent wire
; bytes, so the two derivations are identical by construction and neither has
; to survive the kernel.
;
; All four cells are the game's own kernel scratch, and the census proves each
; is untouched across both bands. They are NOT free cells; they are cells
; whose game lifetime and netcode lifetime do not overlap.
DMSWA   EQU     $80             ; synthetic SWCHA  -- 11 patch sites read it
DMSWB   EQU     $87             ; synthetic SWCHB  --  9 patch sites
DMTR4   EQU     $A9             ; synthetic INPT4  --  2 patch sites
DMTR5   EQU     $AA             ; synthetic INPT5  --  2 patch sites

; ---------------- where the evicted game state now lives ----------------
;
; Plane 5 is $1A80-$1AFF. These offsets put the two blocks at plane-local $60
; and $70, which is text rows 16-18 of columns 10-11 -- so A CLIENT IN A MATCH
; MUST NOT RENDER TEXT ROWS 16-20. The session screens finish before a match
; starts and the blocks are seeded at round start, so the two never overlap;
; fujinet-battleship carries the same rule for rows 5-14 and for the same
; reason.
;
; Reads are ordinary cartridge reads and cost exactly what the zero-page ones
; did: the planes are 128-byte aligned, so `lda DMDOTS,x` with x <= 8 cannot
; page-cross and is always four cycles, never five.
DMDOTS  EQU     $1AE0           ; was $AC,X -- 9 bytes, the per-row dot bitmap
DMSAVB  EQU     $1AF0           ; was $BC,X -- 7 bytes, player B's saved state
DMDOTSO EQU     DMDOTS-FNTEXT   ; the same two, as plane OFFSETS, which is what
DMSAVBO EQU     DMSAVB-FNTEXT   ;   FN_BLIT_POKE's destination takes

; ---------------- DMENT ----------------
DME_NET EQU     $01             ; in a match
DME_ROLE EQU    $02             ; 0 host (left port), 1 guest (right port)
DME_RAN EQU     $04             ; the game bank's cold path has run
DME_LEFT EQU    $08             ; the peer is gone
DME_RSY EQU     $10             ; a resync is pending, one-shot
DME_WARM EQU    $20             ; distinguishes G3's two entries
DME_PHI EQU     $C0             ; frame-in-tick, bits 6-7
;
; The frame-in-tick counter lives in BITS OF THIS BYTE and not in a cell of
; its own, and that is not to save a byte. The cell that says which frame of
; the tick this is must live somewhere the game has no instruction that
; touches (Combat 4.20), and every cell this netcode owns was the game's
; yesterday. DMENT is the one byte the game never had.

; ---------------- the tick ----------------
DMK     EQU     4               ; frames per tick
DMKM    EQU     DMK-1           ; ...as a mask, which is why it is a power of 2
DMD     EQU     2               ; ticks of delay: 2 ticks = 8 frames = ~133 ms,
                                ;   symmetric, and validated against the
                                ;   relay's START so the two cannot disagree
DMWIN   EQU     3               ; ticks of input in every record, newest first

; ---------------- the wire byte ----------------
;
; Port space, and it keeps the hardware's ACTIVE-LOW sense the whole way.
; IDLE is $FF and the rings are seeded with it, never with zero: a zero byte
; reads as every console switch pressed and the stick shoved in all four
; directions at once (Combat 4.8).
IW_TRIG EQU     $80             ; 1 = released
IW_DIFF EQU     $40             ; 1 = A / Pro
IW_SEL  EQU     $20             ; 1 = not pressed
IW_RST  EQU     $10             ; 1 = not pressed
IW_STIK EQU     $0F             ; R L D U, 1 = not pushed
IW_IDLE EQU     $FF
IR_SEED EQU     $A5             ; salts the XOR check byte over a record
; Frame types, matching server/dodgem_relay_server.py. Only these two can
; arrive during play; everything else belongs to the session.
WT_INPUT EQU    $06
WT_LEFT EQU     $0B             ; the peer left
IR_MASK EQU     $F8             ; whole records only -- see dmnet.inc's note on
                                ;   why this port does not need the family's
                                ;   two-consecutive-readings settle rule
IR_LEN  EQU     8               ; every frame a console can receive DURING
                                ;   PLAY is exactly this long, which is what
                                ;   lets the reader take whole records with an
                                ;   AND and never misframe

; ---------------- the timed band ----------------
;
; The net machine is stepped in front of the VBLANK spin at $F244, not the
; overscan one at $F4EA. Three reasons, and `make slack` has to confirm the
; first: the vblank band is armed with $28 (2560 cycles) against overscan's
; $24 (2304); the four bytes before $F244 are `LDA #$4C / STA $9A`, an
; unconditional pair that a hook can displace and re-do, where the four before
; $F4EA are a conditional; and the vblank spin exits into `STA CXCLR / STA
; WSYNC`, which absorbs an overrun, whereas the overscan spin exits into
; `JMP $F0E4` and an overrun there MOVES VSYNC.
;
; Hook in FRONT of the spin, never in place of it (Tennis 2.2): the stock spin
; still runs and still leaves the accumulator as the next instruction expects.
DMGATE  EQU     8               ; TIM64T decrements every 64 cycles, so 8
                                ;   guarantees 7 * 64 = 448 cycles remain
                                ;   against a worst step of about 310
DMBAND  EQU     0               ; 0 = vblank, 1 = overscan. `make slack`
                                ;   decides it; losing that argument is this
                                ;   line plus a different hook in patches.py

; ---------------- the network machine ----------------
NS_IDLE EQU     0
NS_WISS EQU     2               ; WRITE issued
NS_WACK EQU     4
NS_SISS EQU     6               ; STATUS issued
NS_SACK EQU     8
NS_RISS EQU     10              ; READ issued
NS_RACK EQU     12
NS_CONS EQU     14              ; consume the record
NS_FAIL EQU     16

; ---------------- this game's room ----------------
DMAPPKEY EQU    27              ; Combat 24, Video Olympics 24, Dragster 25,
                                ;   Tennis 26. The player NAME is appkey 0 and
                                ;   is shared by every game in the family.
DMPORT  EQU     9603

; ---------------- the banks, and the seams between them ----------------
;
; Four game banks, carved by frame PHASE rather than by address -- see
; tools/dmphase.py. A bank switch is a jump, so everything that runs between
; two switches has to be in one bank, including every subroutine it calls and
; every table it reads.
BANKG0  EQU     0               ; vblank, less the dot engine
BANKG1  EQU     1               ; the dot engine ($F859 and its subtree)
BANKG2  EQU     2               ; the display kernel
BANKG3  EQU     3               ; overscan, and the cold path
BANKBOOT EQU    4               ; cold start, session, text screens

; Some banks are entered at more than one place, so DMGOTO takes an entry index
; in Y as well as a bank in A. That costs nothing here: at every one of the
; five seams A, X and Y are all dead -- each seam lands on an instruction that
; loads its own registers -- which is a happier position than Tennis was in,
; where Y had to survive the switch and the seam had to move to suit.
DMEN_TOP EQU    0               ; G0: the top of the frame ($F0E4)
DMEN_DOT EQU    1               ; G0: resume after the dot engine ($F22B)
DMEN_OVR EQU    0               ; G3: the overscan band ($F420)
DMEN_CLD EQU    1               ; G3: the cold path ($F0CA)

; DMGOTO's address is fixed HERE and dmtail.asm ORGs to it, so the two cannot
; drift apart. It must be first in the tail: it is the one address every bank
; has to know before anything else is assembled.
DMGOTO  EQU     FNTAIL

; ---------------- the variation whitelist ----------------
;
; SELECT walks TWO quantities, not one. $F162 advances $94's mode bits through
; 00 -> 80 -> C0 -> 00 and in the same breath advances $96 & $F8 through
; $58 -> $88 -> $B8 -> $58. A whitelist that pins only $94 leaves two consoles
; agreeing about the variation while playing different LEVELS, and every gate
; that compares agreement would pass.
DMMODE  EQU     $C0             ; $94 bits 7,6: both players active -- they
                                ;   alternate who dodges, and whoever is not
                                ;   dodging drives the chase car
DMLEVEL EQU     $B8             ; $96 & $F8 that goes with it

; ---------------- assertions ----------------
;
; DMREMOTE indexes the peer's window with `lda DMRIN0,x` and the mixer shifts
; the local one, so both must be three contiguous cells. Stated here, at the
; allocation, rather than trusted to whoever next rearranges it.
        IF      DMRIN1 <> DMRIN0+1
        ERROR   "DMRIN1 is not DMRIN0+1"
        ENDIF
        IF      DMRIN2 <> DMRIN0+2
        ERROR   "DMRIN2 is not DMRIN0+2"
        ENDIF
        IF      DMLOC1 <> DMLOC0+1
        ERROR   "DMLOC1 is not DMLOC0+1"
        ENDIF
        IF      DMLOC2 <> DMLOC0+2
        ERROR   "DMLOC2 is not DMLOC0+2"
        ENDIF
