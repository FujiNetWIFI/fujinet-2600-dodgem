; dmstart.inc -- the game bank's cold path, the bounded clear, and seam A.
;
; All three live in the hole the display half left at $1015-$1167, and seam A's
; trampoline has to be the FIRST thing in it, because $1015 is an address the
; stock game jumps to.

; ---------------------------------------------------------------------------
; DMSEAMA -- game -> display.
;
; TWO WAYS IN AND ONE TRAMPOLINE SERVES BOTH, and neither costs a patched byte:
;
;   $F494  JMP LF015      every frame, the end of the game logic
;   $F014  fall-through   the cold path, out of `JSR LF5E7`
;
; Both are stock instructions, unmodified. In the game bank $1015 is a hole --
; it belongs to the display half -- so the trampoline simply occupies the
; address they already name.
;
; NOTHING IS LIVE ACROSS IT. $F015 is `LDA #$36 / LDX #$02 / JSR LF4A3`, which
; loads A and X before reading either, and LF4A3 writes Y with `TAY` before it
; reads Y. So DMGOTO's clobber of A and X costs nothing here.
;
; The cycles it spends are inside the timed band armed at $F1A2 and spun out at
; $F051, so the spin absorbs them and the frame does not change length. That is
; the whole reason the band is the right place to hang everything: `make frames`
; checks it rather than trusting it.
        ORG     DMSEAMA
        lda     #BANKKERN
        jmp     DMGOTO

; ---------------------------------------------------------------------------
; DMCLR -- Dodge 'Em's RAM clear, bounded.
;
; Stock is six bytes at $F004:
;
;       LF004: LDY #$00
;       LF006: STY VSYNC,X
;              TXS
;              INX
;              BNE LF006
;
; `STY VSYNC,X` is `STY $00,X`, which wraps inside page zero, so a run from
; X = 0 covers the whole TIA register file AND all 128 bytes of RAM in one
; two-byte instruction. That is 1981 economy and it is also the thing that
; would wipe every netcode cell.
;
; THREE ENTRIES, ONE LOOP -- Dragster's trap with an extra door:
;
;       cold      X = $00   from the boot bank, through the dispatcher
;       RESET     X = $85   `LDX #$85 / JMP LF004` at $F1A9
;       SELECT    X = $88   `LDX #$88 / JMP LF004` at $F1D0
;
; The last two happen several times a minute while somebody is choosing a game,
; so an unbounded clear would not be a rare hazard; it would be the normal case.
;
; What the bound costs in behaviour is nothing, and that is checkable rather
; than hopeful: the highest cell any Dodge 'Em instruction names is $D5, so
; $D6-$FF is read by nothing in the game. `make det` is what says so.
DMCLR:
; THE COLD PATH RECOGNISES ITSELF, because it is the one entry that cannot
; carry its seed in X: DMGOTO leaves X = $FF, and $FF would clear exactly one
; byte and then wrap out of the loop. The other two entries are stock `LDX #imm`
; instructions and still work exactly as they did.
        bit     DMWARM
        bmi     DMCLR0
        ldx     #$00
DMCLR0: ldy     #$00
DMCLR1: sty     VSYNC,X         ; $00,X -- the TIA below $80, RAM above it
        inx
        cpx     #DMZPLO
        bne     DMCLR1

; THE STACK POINTER IS NOT A SIDE EFFECT ANY MORE. Stock got SP = $FF out of a
; `TXS` inside the loop, which works only because the loop ends with X = $FF.
; A bounded loop ends with X = DMZPLO, so the TXS comes out of the loop and the
; value is stated.
        ldx     #$FF
        txs

; The rest of stock's $F00C-$F014, unchanged in effect. `STX AUDV0` becomes
; `STY AUDV0` only because it is Y and not X that is still zero here; the clear
; has already strobed AUDV0 on its way past, so this is stock's own belt and
; braces kept rather than dropped.
        sty     AUDV0
        lda     #$11
        sta     CTRLPF
        jsr     LF5E7

; A MATCH HAS TO COME UP ON A TWO-HUMAN VARIATION, and only the cold path can
; do it. The clear leaves $80 at zero, and $81 is $80 AND 1, so a networked
; console that did nothing here would start with the COMPUTER playing one side
; -- identically on both machines, which is exactly why it would look fine.
;
; It is guarded on cold, because the other two entries do not reach $80: the
; RESET clear starts at $85 and the SELECT clear at $88, so the variation the
; player chose survives both.
        bit     DMWARM
        bmi     DMCLR8
        lda     DMENT
        and     #DME_NET
        beq     DMCLR8
        lda     #1
        sta     $80
        sta     $81

; And the warm mark, set where it cannot be missed: every path that reaches the
; display half from here goes through the trampoline below.
DMCLR8: lda     #$80
        sta     DMWARM
        jmp     DMSEAMA
