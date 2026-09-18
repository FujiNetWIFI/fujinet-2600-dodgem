; dmboot.asm -- bank 4: cold start, and (later) the session.
;
; DMCOLD in the fixed tail arms the cartridge and enters here. For now this
; bank does the one thing it must: hand the console to the game, cold and NOT
; networked, by entering G3 at its cold path.
;
; That order is deliberate and it is what makes `make det` possible. Combat's
; PORTING.md 4.13 puts it as a rule -- A CARTRIDGE WITH NO SERVER IS STILL A
; DODGE 'EM CARTRIDGE -- and the gate that proves this build plays exactly like
; the 1980 ROM depends on the un-networked path being the plain one rather than
; a special case bolted on afterwards. The session will be added in FRONT of
; this handover, not around it, and every way it can fail will end up here.

        CPU     6502
        INCLUDE "vcs.inc"
        INCLUDE "fujinet.inc"
        INCLUDE "dmdefs.inc"

        ORG     $1000

; The entry dispatcher, the same shape every bank has. This one has a single
; entry, so Y is ignored.
        jmp     DMBOOT

DMBOOT:
; SEED THE EVICTED BLOCK.
;
; Stock clears $80-$FF at cold start -- $F0D1's `STA $00,X` sweeps the whole
; page -- and player B's saved state at $BC-$C2 comes out of that as zero. In
; this build those seven bytes live in a cartridge text plane, and the sweep
; cannot reach them: it writes RAM, and the plane is not RAM.
;
; Nothing else will do it either. The dot bitmap at $AC-$B4 is seeded by the
; game's own LF032, whose store is patched to a poke -- but $BC-$C2 has no
; initialiser of its own in the game, because the cold clear WAS its
; initialiser. So it is one here.
;
; Found by `make det`: the plane came up holding $FF where stock held $00, and
; the two builds diverged on the first frame that read it.
        ldx     #6
        lda     #0
DMSEED: jsr     DMPOKEB
        lda     #0
        dex
        bpl     DMSEED

; DMENT was zeroed by DMCOLD, so the game starts un-networked: no DME_NET, no
; role, no tick. Nothing here may write DMENT's other bits before the session
; exists, because a half-set flag is worse than a clear one.
        lda     #BANKG3
        ldy     #DMEN_CLD
        jmp     DMGOTO

        INCLUDE "dmpoke.inc"

        END
