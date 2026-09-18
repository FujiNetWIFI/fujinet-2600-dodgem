; dmsess.inc -- the boot bank: the socket, the handshake, and the fallback.
;
; Everything that happens ONCE, before a match, and nothing that happens during
; one. It is the only bank that may use the session half of the zero-page union
; -- FNDEV, FNCMD, FNNPR, FNTMO and FNCNT share addresses with the lockstep
; windows, and the two are never live together because this bank finishes
; before the game bank starts.
;
; EVERY FAILURE IS SOFT AND LANDS IN THE SAME PLACE. No cartridge, no SD card,
; no Lobby key, no relay, no opponent: all of them fall through to DMSLOC,
; which hands the console to the game un-networked. Combat's PORTING.md 4.13 is
; the rule -- a cartridge with no server is still a Dodge 'Em cartridge -- and
; `make det` depends on it, because the path it proves byte-identical to the
; 1980 ROM is the one every failure here arrives at.
;
; The reason is kept in DMERR's low nibble so a screen can say which it was
; without the code having to branch differently for each.

STARTLEN EQU    15              ; len + type + 13 bytes of START payload

; How many times to ask the relay whether it has paired us.
;
; EACH POLL IS A BLOCKING TRANSACTION AND COSTS ROUGHLY A FRAME, and while it
; runs the console is not drawing one -- `make frames` measured 358 frames of
; 421 lines during a boot with no relay listening, against stock's steady 261.
; So this is a budget, not a patience setting: about a second of waiting for a
; relay that is not there, and instant when one is, because pairing happens the
; moment the second console connects.
;
; The real answer is to pace the wait against the boot bank's own display
; kernel -- one poll per drawn frame -- so a player can wait for an opponent
; for as long as they like with a stable picture. dmdisp.inc is here for that
; and is not wired up yet; see PORTING.md 13.
DMSTPOLL EQU    64

; ---------------------------------------------------------------------------
; DMBENT -- the boot bank's entry. DMCOLD in the tail arms the cartridge and
; jumps here.
; ---------------------------------------------------------------------------
DMBENT:
; A BOUNDED CLEAR, and then an entry past the game's own.
;
; $F0CA sweeps $00-$FF -- the TIA and every byte of RAM. That is right for a
; cold start and fatal after a session: it wipes the very cells the socket and
; the handshake were spent filling. So this clears what the game needs cleared
; and nothing else, and a networked handover enters G3 PAST the sweep.
;
; Counting DOWN from $7F. Counting up from $00 to $FF would be the stock
; sweep's shape and would take the netcode's cells with it; counting down from
; the top of the TIA stops exactly where it should.
        lda     #0
        ldx     #$7F
DMBCLR: sta     $00,x           ; the TIA, which the game expects cleared
        dex
        bpl     DMBCLR
        ldx     #$2B            ; $80-$AB, the game's own variables
DMBCL2: sta     $80,x
        dex
        bpl     DMBCL2
        ldx     #$06            ; $B5-$BB, player A's saved block
DMBCL3: sta     $B5,x
        dex
        bpl     DMBCL3
        ldx     #$35            ; $C3-$F8, the six playfield streams
DMBCL4: sta     $C3,x
        dex
        bpl     DMBCL4

        jsr     FNARM
        jsr     FNCHK           ; Z set if 'F','N' is there
        beq     DMB1
        lda     #FNENOC
        bne     DMSLOCE         ; no cartridge at all

DMB1:
; The room's URL, out of appkey 27 and into path buffer 0. It never touches
; console RAM: a URL is sixty-four bytes against the seventeen this netcode
; owns, so it goes from the reply window straight into the cartridge's own
; buffer and is emitted from there when the OPEN is built.
        lda     #DMAPPKEY
        ldx     #FP_SEL0
        jsr     CSAKGET

; ASK THE CARTRIDGE, NOT THE ROUTINE.
;
; CSAKGET's contract is "A = 0 on success", and on a key that does not exist it
; came back zero anyway -- fujinet-pc logs `fopen ... err` and the console saw
; a perfectly ordinary empty reply. Rather than depend on a convention that is
; already once wrong, test the thing that actually matters: the cartridge
; publishes the active buffer's length at $1F17 and republishes it on every
; change, so an empty buffer is a fact rather than an inference.
        lda     FNPLEN
        ora     FNPLEN+1
        bne     DMB2

; NO KEY IS NOT A FAILURE. A console with no SD card, a Lobby that has never
; written the room, a fresh tree with nothing published: all of them should
; still reach a relay, because a cartridge that refused to play because it
; could not read a PREFERENCE would be a worse cartridge. So fall back to the
; endpoint baked in at build time -- which is also what makes `make session`
; testable at all, since a lone relay on localhost has no Lobby behind it.
        jsr     DMFALLB

DMB2:
        jsr     DMOPEN
        bcc     DMSLOCF
        jsr     DMHELLO
        bcc     DMSLOCF
        jsr     DMSTART
        bcc     DMSLOCF

; ---- paired. Seed the lockstep and hand over ----
;
; SEEDED WITH IDLE, NEVER WITH ZERO. The wire keeps the hardware's active-low
; sense, so a zero byte reads as every console switch pressed and the stick
; shoved in all four directions at once (Combat 4.8). The first frames of a
; match run on these bytes.
        lda     #IW_IDLE
        sta     DMLOC0
        sta     DMLOC1
        sta     DMLOC2
        sta     DMRIN0
        sta     DMRIN1
        sta     DMRIN2
; The tick starts BELOW zero and the watermark below that, so the first real
; record is unambiguously newer than the seed and the first comparison in
; DMREMOTE is a stall rather than an accidental match.
        lda     #$FF
        sta     DMTICK
        lda     #$FE
        sta     DMRWAT
        lda     #NS_WISS
        sta     DMNST

; DMENT BEFORE DMRDN, because DMROLE *IS* DMRDN.
;
; The union is documented three files away and the seeding block zeroed the
; record cursor first, which threw the role away before reading it -- so the
; guest came up as a host, both consoles put their own stick in the high
; nibble, and every checksum agreed because the error was symmetric.
;
; The lesson is not "be careful with unions". It is that a union whose two
; halves are named differently reads as two cells, and this ordering is the
; only thing keeping it honest.
        lda     DMROLE
        and     #1
        asl                     ; 0 -> $00 host, 1 -> $02 guest
        ora     #DME_NET
        sta     DMENT

        lda     #0
        sta     DMERR
        sta     DMRDN
        jmp     DMHAND

; ---- every failure arrives here ----
DMSLOCF:
        lda     #FNEBAD
DMSLOCE:
        sta     DMERR
DMSLOC:
        lda     #0
        sta     DMENT           ; not networked: the plain game
DMHAND:
        lda     DMENT
        and     #DME_NET
        beq     DMHCOLD
        lda     #BANKG3
        ldy     #DMEN_NET       ; past the clear: we have something to lose
        jmp     DMGOTO
DMHCOLD:
; NOT networked, so take the STOCK path, clear and all. That is what makes
; `make det` mean something: the build it proves byte-identical to the 1980
; cartridge is the one that goes through $F0CA exactly as the cartridge does.
        lda     #BANKG3
        ldy     #DMEN_CLD
        jmp     DMGOTO

; ---------------------------------------------------------------------------
; DMFALLB -- put the build-time endpoint into path buffer 0.
;
; A character at a time through the cartridge's own path port, because the
; string is in ROM and the buffer is in the cartridge: nothing passes through
; console RAM, which has none to spare.
; ---------------------------------------------------------------------------
DMFALLB:
; ONE STORE PER OPERATION, and no commit.
;
; FH_PATHO and FH_PATHC are in the bit-7-set half of the control page, which is
; the ONE-SHOT half: the data comes from the store itself and there is nothing
; to arm. The arm-then-commit pair belongs to the REGISTERS below $80, and a
; `sta FNCMT` after a one-shot does not complete it -- it commits whatever
; register happened to be armed last, carrying this store's value.
;
; The symptom was not an error. fujinet-pc logged `rs232_open()` and then
; `deviceSpec is empty, returning empty string`, and the relay never saw a
; connection at all.
        lda     #FP_SEL0
        sta     FNRSEL+FH_PATHO
        lda     #FP_RST
        sta     FNRSEL+FH_PATHO
        ldx     #0
DMFB1:  lda     UENDPT,x
        beq     DMFB9
        sta     FNRSEL+FH_PATHC
        inx
        bne     DMFB1
DMFB9:  rts

; ---------------------------------------------------------------------------
; DMOPEN -- N: OPEN the room, in READWRITE.
;
; The devicespec is streamed out of the cartridge's path buffer straight into
; the TX page: FP_TXRAW emits exactly the bytes it holds and this client pads
; nothing, because OPEN takes a counted payload rather than a fixed 256.
; Carry set on success.
; ---------------------------------------------------------------------------
DMOPEN:
        lda     #NETDEV
        sta     FNDEV
        lda     #NCOPEN
        sta     FNCMD
        lda     #2
        sta     FNNPR
        jsr     FNBEG
        lda     #NMRDWR
        jsr     FNPB
        lda     #0              ; translation: none
        jsr     FNPB
        lda     #FP_SEL0
        sta     FNRSEL+FH_PATHO
        lda     #FP_TXRAW
        sta     FNRSEL+FH_PATHO
        jmp     DMGOOK

; ---------------------------------------------------------------------------
; DMHELLO -- say who we are.
;
; ver(1) tv(1) name(2-8). The television standard is between the version and
; the name and that is a payload SHAPE, not a field the relay can skip: a
; console built for PAL and a relay expecting protocol 1 disagree about where
; the name starts.
; ---------------------------------------------------------------------------
DMHELLO:
        lda     #NETDEV
        sta     FNDEV
        lda     #NCWRITE
        sta     FNCMD
        lda     #1
        sta     FNNPR
        jsr     FNBEG
        lda     #DMHLEN
        ldx     #0
        jsr     FNPW            ; ONE two-byte parameter: the length
        lda     #DMHLEN-1
        sta     FNTX
        lda     #WT_HELLO
        sta     FNTX
        lda     #2              ; protocol version
        sta     FNTX
        lda     #DMTVSTD
        sta     FNTX
        ldx     #0
DMHN:   lda     DMNAME,x
        sta     FNTX
        inx
        cpx     #DMNLEN
        bne     DMHN
        jmp     DMGOOK

; ---------------------------------------------------------------------------
; DMSTART -- wait for the relay to pair us, then take the START.
;
; It blocks, and that is right here: there is nothing else for the console to
; do and no simulation to keep running yet. The display-paced poll the netcode
; uses belongs to a match.
; ---------------------------------------------------------------------------
DMSTART:
        ldy     #256-DMSTPOLL
DMSTW:
        jsr     DMNSTAT         ; how many bytes are waiting?
        bcc     DMSTF
        cmp     #STARTLEN
        bcs     DMSTR
        iny
        bne     DMSTW           ; DMSTPOLL polls, then give up and play alone
DMSTF:  clc
        rts

DMSTR:
        lda     #NETDEV
        sta     FNDEV
        lda     #NCREAD
        sta     FNCMD
        lda     #1
        sta     FNNPR
        jsr     FNBEG
        lda     #STARTLEN
        ldx     #0
        jsr     FNPW
        jsr     FNGO
        cmp     #FNEOK
        bne     DMSTF
        jsr     FNACK
        cmp     #FNEOK
        bne     DMSTF

; The payload: len, type, role, seed_lo, seed_hi, delay, variation, opp(8).
        lda     FNRPLY+1
        cmp     #WT_START
        bne     DMSTF
        lda     FNRPLY+2
        sta     DMROLE          ; 0 host, 1 guest
; VALIDATE THE DELAY. Both consoles compute where a record goes from their own
; DMD, so a relay handing out a different one would pair two machines that
; disagree about which tick an input belongs to -- and every checksum would
; mismatch for a reason that is not a desync.
        lda     FNRPLY+5
        cmp     #DMD
        bne     DMSTF
        sec
        rts

; ---------------------------------------------------------------------------
; DMNSTAT -- bytes waiting, in A. Carry set if the answer is trustworthy.
;
; The parameters are (1, 0) and they go through FNPB, which emits each as a
; SIZE byte and then its value. NET STATUS refuses unit 0, and the symptom is
; not an error: it is a plausible zero, for ever.
; ---------------------------------------------------------------------------
DMNSTAT:
        lda     #NETDEV
        sta     FNDEV
        lda     #NCSTAT
        sta     FNCMD
        lda     #2
        sta     FNNPR
        jsr     FNBEG
        lda     #1
        jsr     FNPB
        lda     #0
        jsr     FNPB
        jsr     FNGO
        cmp     #FNEOK
        bne     DMNSF
        jsr     FNACK
        cmp     #FNEOK
        bne     DMNSF
        lda     FNRPLY+NSDEVST  ; nDevStatus_t; SUCCESS is 1, not 0, and it is
        cmp     #1              ;   the only place a dead socket shows
        bne     DMNSF
        lda     FNRPLY+NSAVLO
        sec
        rts
DMNSF:  clc
        rts

; DMGOOK -- launch, and turn both layers of "did it work" into the carry.
DMGOOK:
        jsr     FNGO
        cmp     #FNEOK
        bne     DMGOF
        jsr     FNACK           ; $06 ACK or $15 NAK: the SERVER's answer, as
        cmp     #FNEOK          ;   opposed to the cartridge's
        bne     DMGOF
        sec
        rts
DMGOF:  clc
        rts
