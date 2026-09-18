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
; DMENT was zeroed by DMCOLD, so the game starts un-networked: no DME_NET, no
; role, no tick. Nothing here may write DMENT's other bits before the session
; exists, because a half-set flag is worse than a clear one.
        lda     #BANKG3
        ldy     #DMEN_CLD
        jmp     DMGOTO

        END
