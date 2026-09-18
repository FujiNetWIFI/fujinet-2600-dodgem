; dmtail.asm -- the fixed half: the trampoline, the shared transport, the cold
; stub and the vectors.
;
; $1800-$1F1F is the cartridge's mailbox -- text planes, reply window, control
; page, TX page, status -- and the cartridge paints it. The client owns
; $1F20-$1FFB, which fuji_mailbox.h calls the fixed tail, plus the vectors.
;
; Everything here has to be at an address that does not move, for three
; separate reasons:
;
;   * The store that switches bank is the LAST instruction fetched from the old
;     bank and the very next fetch comes from the new one, so the jump after it
;     cannot live in a bank.
;   * This console has no reset line to the cartridge. The RESET switch
;     restarts the 6507 with whatever bank was last selected still mapped, so a
;     cold stub living in a bank would simply not be there when it was needed.
;   * The transport is the same bytes in every bank, and a bank is 2048. Here
;     it is one copy all of them can reach.

        CPU     6502
        INCLUDE "vcs.inc"
        INCLUDE "fujinet.inc"
        INCLUDE "dmdefs.inc"

DMHASTXT EQU    1               ; the tail carries the text primitives; if it
                                ;   ever runs short they move into the boot
                                ;   bank, the only one that draws text

        ORG     DMGOTO

; ---------------------------------------------------------------------------
; DMGOTO -- select bank A and enter it at $1000 with entry index Y.
;
; ONE store. FN_HOT_BANK lives in the bit-7-set half of the control page, which
; is the one-shot half: the bank number is in the ADDRESS and the data is
; ignored. A store to $1DFF afterwards would be FN_H_COMMIT, and it would
; commit whatever FN_REG_* was last armed, carrying this store's value.
;
; `sta FNRSEL,x` is the documented-safe indexed form: the base low byte is $00,
; so the index cannot carry and the dummy read that STA abs,X always performs
; lands on the same address as the write -- one parked access, not two.
;
; IT PRESERVES Y, which is the entry index the bank's dispatcher reads. A and X
; are clobbered and nothing minds: Dodge 'Em's five seams all land on an
; instruction that loads its own registers, which tools/dmseams.py asserts
; rather than leaving to a comment.
        clc
        adc     #FH_BANK
        tax
        sta     FNRSEL,x
; RESET THE STACK. A bank switch is a JUMP and nothing ever returns through
; one, so every switch abandons whatever return addresses were on the stack.
; That is not a leak to be tolerated -- it is the reason the dot engine's four
; outermost RTS sites had to become switches of their own rather than returns.
;
; These instructions are fetched from the FIXED tail, which is not banked, so
; they still execute after the store above has changed what $1000-$17FF means.
        ldx     #$FF
        txs
        jmp     $1000

; ---------------------------------------------------------------------------
; The shared transport. tools/mktail.py turns the addresses these assemble to
; into build/tail.inc, which is what the banks include.
        INCLUDE "dmcore.inc"

; ---------------------------------------------------------------------------
; DMCOLD -- power-on and RESET.
;
; Deliberately tiny. All that has to be here is what cannot be anywhere else:
; the arming pair, because banking is a control-page operation and that page
; decodes nothing until an ordered pair of stores carrying two specific values
; arrives -- and the bank switch itself.
;
; SEI and CLD are here because this is where stock did them and there is
; nowhere else left: stock's $F000 `JMP LF0CA` is in no bank at all, since
; $1000 of every bank is now that bank's entry dispatcher.
;
; It zeroes DMENT. This console does not clear its RAM on a RESET -- the switch
; is a RIOT bit the program polls, not a line to the 6507 -- so the byte that
; says what the bank being entered should do still holds whatever the last
; frame left in it. Without this, a RESET taken mid-match comes back with a sim
; tick, a ring and a socket that no longer mean anything.
;
; The cartridge's own state is NOT reset, and must not be: the client's next
; sequence number is the cart's persisted ACKSEQ + 1, and the four path buffers
; survive too. That is the whole reason FNGO reads ACKSEQ instead of counting.
DMCOLD: sei
        cld
        ldx     #$FF
        txs
        lda     #0
        sta     DMENT
        lda     #FNAM1
        sta     FNRSEL+FH_ARM1
        lda     #FNAM2
        sta     FNRSEL+FH_ARM2
        lda     #BANKBOOT
        ldy     #0
        jmp     DMGOTO

; ---------------------------------------------------------------------------
; THE VECTORS.
;
; Both point at the cold stub, and that is asserted rather than assumed.
; Video Olympics could not do this: it issues BRK three times as a two-byte
; subroutine call, so its IRQ vector had to point back into real code. Dodge
; 'Em issues no BRK at all -- tools/checkmap.py proves it on every build, by
; recursive descent -- and its stock NMI and IRQ vectors are both $0000, so
; neither was ever taken on the original cartridge either.
        ORG     $1FFC
        DW      DMCOLD          ; RESET
        DW      DMCOLD          ; IRQ/BRK -- never taken; there is no BRK

        END
