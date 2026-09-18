; dmmix.inc -- fill the synthetic controller.
;
; The twenty-four patched read sites do not read a console port any more; they
; read DMSWA, DMSWB, DMTR4 and DMTR5. This is the one place those are written,
; and `make inputs` is the gate that says so: after the patch, every read of a
; real port in a whole run comes from in here.
;
; IT RUNS TWICE A FRAME, once at the head of each band, from each bank's entry
; dispatcher. That is not waste. The four shadows are BAND-LOCAL -- they live
; in cells the game owns and does not touch across a band, because there were
; no other cells to have (dmdefs.inc) -- so they do not survive the kernel and
; have to be rebuilt on the far side of it. Both derivations come from the same
; inputs, so they cannot disagree.
;
; The un-networked path is the PLAIN one and the networked path will be added
; in front of it. Combat's PORTING.md 4.13 is the rule: a cartridge with no
; server is still a Dodge 'Em cartridge, and `make det` -- the gate that proves
; this build plays exactly like the 1980 ROM -- depends on the local path being
; ordinary rather than a special case bolted on afterwards.
;
; Preserves Y. The dispatcher still needs it: it is the entry index DMGOTO
; carried in, and the jump that follows this call reads it.

DMMIX:
        IF      1               ; the networked path goes here, in front
        ENDIF

; ---- DMLOC0: not in a match, so the console drives both cars ----
;
; Straight through, with the hardware's own active-low sense intact. Nothing is
; normalised and nothing is decoded: the eight turn-decision sites each pick
; their own bits out of SWCHA -- one pair does LSR/LSR/LSR/BCC on the right
; port's, another BPL/ASL/BMI on the left's -- and they all work unchanged as
; long as what they read is a faithful SWCHA. Mixing in PORT space and letting
; the game's own `BIT $98` decide who is driving what is the whole reason the
; twenty-four patches are one-instruction swaps.
        lda     SWCHA
        sta     DMSWA
        lda     SWCHB
        sta     DMSWB
        lda     INPT4
        sta     DMTR4
        lda     INPT5
        sta     DMTR5
        rts
