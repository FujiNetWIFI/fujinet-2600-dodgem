# Porting Dodge 'Em to network play

The sibling documents are [`fujinet-2600-combat/PORTING.md`][cb], which is the
doctrine, [`fujinet-2600-video-olympics/PORTING.md`][vo],
[`fujinet-2600-dragster/PORTING.md`][dg] and
[`fujinet-2600-tennis/PORTING.md`][tn]. All four are assumed: everything they
say about the mailbox, the arm-then-commit rule, the sequence number coming
from the cartridge and not from RAM, the immutability of a sent record and the
shape of the gates is still true and is not repeated here.

[cb]: ../fujinet-2600-combat/PORTING.md
[vo]: ../fujinet-2600-video-olympics/PORTING.md
[dg]: ../fujinet-2600-dragster/PORTING.md
[tn]: ../fujinet-2600-tennis/PORTING.md

This document is what is new. Two things are, and both are firsts for the
family:

**Dodge 'Em is a true 4K game.** Combat, Video Olympics, Dragster and Tennis
were all 2K and fit one bank with room left over for the netcode to live in
the holes. This one is 3426 bytes of code and 466 of data.

**Dodge 'Em has no free RAM.** Not "very little". None.

---

## 1. The measurements, before any porting

### 1.1 The disassembly is exact, and says so

`tools/dodgem.cfg` is two lines:

```
ORG F000
DATA FD62 FFFF
```

`make verify-org` makes two claims and only the second is a round trip.
`tools/checkmap.py` walks the image by recursive descent from the reset vector
and requires the declared split to be the one it finds; then the generated
source is assembled and `cmp`'d against the dump.

```
checkmap: 1725 instructions, 3426 code bytes, 670 data bytes
checkmap: reset $F000; no JMP (ind), no BRK
checkmap: PASS -- the declared split is the one descent finds
verify-org: byte-identical (4096 bytes)
```

Both halves matter and Tennis §5 says why the `cmp` alone does not: *a run of
data bytes disassembled as instructions re-encodes to exactly the bytes it came
from*, so the round trip cannot see a wrong split at all.

Two findings from the descent are load-bearing later:

- **No `JMP (ind)` and no RTS-dispatch.** The descent is therefore EXACT and
  not a lower bound, which is what makes the bank-split analysis in §3
  trustworthy. Video Olympics §3.2 had the opposite problem.
- **No `BRK`, and the IRQ/NMI vectors are `$0000`.** Video Olympics §3.1 found
  `BRK` used as a two-byte subroutine call with a live IRQ handler — *"before
  banking a ROM, find out what its IRQ and NMI vectors are for"*. Here they are
  for nothing, so the fixed tail has one entry point to own rather than two.
  `checkmap.py` asserts it rather than leaving it as a note.

`checkmap.py` was extended to take the window from the image SIZE rather than
hardcoding `$F000-$F7FF`. A 2048-byte dump sits at `$F800` and a 4096-byte one
at `$F000`, and the reset vector is at the top of whichever it is; inheriting
the sibling constant reads the vector out of the middle of the game.

### 1.2 Zero page: all 128 bytes, and the census that proves it

`make zp` is a new gate. It exists because the family's own `recon.py` reports
a free upper bound of **69 cells** here, and the true figure is **zero** — the
same over-count that printed 62 for Combat where the truth was 26.

Two things make the naive answer wrong, and `tools/zpmap.py` now handles both
rather than leaving them to the reader:

- **Every indexed base is BOUNDED.** `LDA $C3,X` under `LDX #$08` touches nine
  cells, and a scan that records the operand byte alone reports eight of them
  as free. The tool walks back from each access to the instruction that last
  loaded its index. Forty-two sites take their index from memory rather than an
  immediate — the kernel's `LDX $A9`, `LFD14`'s X live from its caller — and
  each of those is named in a `HAND` table with what bounds it, in the spirit
  of Dragster's `dgmap.py`: the single place the map is written down. **A site
  that is neither auto-bounded nor named is a hard failure**, so the table
  cannot silently rot.
- **The cold clear is excluded.** `$F0D1` is `STA VSYNC,X` inside
  `LDX #$FF / TXS / INX / TXA / … / INX / BNE`, so it sweeps `$00-$FF` — every
  TIA register and all 128 bytes of RAM. Counting it as a use attributes every
  cell in the machine to the cold phase and says nothing. It is reported apart,
  because it is also the hazard all four siblings hit (Combat §4.12, VO §3.4,
  Dragster §3.4, Tennis §2.6). **It reaches the reset VECTOR only, not the
  RESET SWITCH**, which on this console is a RIOT bit the program polls at
  `$F162` — so netcode state set up after cold start survives a player pressing
  RESET. That is asserted, not assumed.

The map:

| range | bytes | what |
|---|---|---|
| `$80-$AB` | 44 | game variables |
| `$AC-$B4` | 9 | per-row dot bitmap, EOR'd at four sites |
| `$B5-$BB` | 7 | player A's saved state block |
| `$BC-$C2` | 7 | player B's saved state block |
| `$C3-$F8` | 54 | six playfield streams × 9 rows |
| `$F9` | 1 | never touched |
| `$FA-$FF` | 6 | stack — measured, not assumed (§1.3) |

121 + 1 + 6 = 128.

### 1.3 What "free" actually had to mean

The first version of this gate asked the wrong question, and the wrong question
had a comfortable answer. It reported the cells dead across the overscan band —
nineteen of them, including the twelve score pointers at `$88-$93` — and that
looks like plenty until you ask what the netcode would keep there.

There are two kinds of netcode cell and only one of them fits:

- **SCRATCH** is born and dies inside one overscan band: the network machine's
  working registers. It needs a cell the game does not touch *during* that band.
  Nineteen are available.
- **PERSISTENT** must survive from one overscan band to the *next*: the tick,
  the sequence, the four input shadows, the delay ring. It needs a cell the
  game **never writes at all** — because anything the game writes in vblank or
  the kernel lands squarely between two overscan bands and wipes it.

Dodge 'Em does its scoring in VBLANK (`LF228: JSR LF859`, the dot-collision and
digit-pointer advance) and its movement in overscan. So `$88-$93` are dead
across the band and useless anyway: the kernel and vblank rewrite them every
frame.

The stack floor is measured. The deepest JSR chain from any of the four phase
entries is **6 bytes**, so the stack is `$FA-$FF` and `$F9` is the one cell
below it that the game never writes.

```
VERDICT: the netcode needs 16 bytes of PERSISTENT state (dmdefs.inc).
         1 are available below the stack floor: $F9.
         FAIL -- short by 15.
```

**The rule, for the next port:** *a cell that is dead when your code runs is not
the same as a cell your code may keep something in. Ask which of the two you
need before you count.*

---

## 2. Why there is no in-console answer

Before escalating, the alternatives were worked through, because escalation
means touching three other repositories:

- **Compose the input byte on the relay** so the console reads a mixed `SWCHA`
  straight out of the reply window and needs no shadows. Refused: it makes the
  console depend on the network for *its own stick*, and Combat §4.13's rule is
  that a cartridge with no server is still a Dodge 'Em cartridge.
- **Recompute the shadows every frame** from the local ring and the reply
  window instead of storing them. The ring is still RAM, and the recomputed
  value still has to be *somewhere* the twenty-four patch sites can read it in
  vblank and in the kernel. Circular.
- **Keep state in the cartridge's path buffers** and read it back with
  `FN_BLIT_PATH`. The buffers are write-only from the console and the blit
  renders *glyphs*, so recovering a byte needs the font to be injective over
  0-255. It is not — `fuji_mailbox.h` records three glyph pairs that were
  bit-identical and had to be redrawn.
- **Store bytes as hex digit pairs** in text cells and decode the plane bits
  back. The sixteen hex glyphs *are* distinguishable, so this one works — and
  costs a blit to write and five scanlines of bit-decoding to read, per byte,
  per frame. Fine for a cold value; impossible for the tick and the shadows.

So the escalation is not a shortcut taken early. It is the only thing left.

---

## 3. The bank split, which is the one piece of good news

Scanning every 8-byte boundary in the code region for control transfers that
cross it — branches cannot be trampolined, `JSR`/`JMP` can:

| split | cross-boundary branches | cross-boundary jumps |
|---|---|---|
| `$F800` (the naive midpoint) | **10** | 34 |
| **`$F5A0`** | **0** | 12 |
| **`$FC48`** | **0** | 6 |

The game divides into three banks at `$F5A0` and `$FC48` with **no duplicated
code at all** — 1440 / 1704 / 748 bytes — and 18 cross-bank jumps to route
through one parameterised `DMGOTO` in the fixed tail. That is the opposite of
Dragster §4, where `StageRace` jumped into the middle of `PositionSprites` and
72 bytes had to be carried in both banks.

Choosing 16384 bytes rather than 8192 is what makes it affordable: the split
points are picked where the code actually divides, not where the arithmetic
forces them. *Worth doing early in the next port:* compute the cross-bank
reference set for every candidate boundary before choosing one, not after.

Tables are duplicated into each bank that reads them — a bank that is not
mapped cannot be read — costing about 416 bytes against 466 of original data.

---

## 4. The hazard with no sibling precedent

Dodge 'Em's data occupies `$FD62-$FF33`. Rebased into the cartridge window,
**all of it lands on pages the cartridge owns**:

```
$FD62-$FD7F  ->  $1D62-$1D7F   control page: a read arms a register
$FD80-$FDEF  ->  $1D80-$1DEF   control page: *** A READ SWITCHES THE BANK ***
$FDF0-$FDFF  ->  $1DF0-$1DFF   control page: blit / path / arm / swap / commit
$FE00-$FEFF  ->  $1E00-$1EFF   TX stream, write-only, never readable
$FF00-$FF33  ->  $1F00-$1F33   status, claim, fixed tail
```

The ~35 absolute references re-point themselves once the tables carry labels.
The danger is the **12 hardcoded pointer high bytes** — `LDA #$FE / STA $A1`
and its siblings — feeding `LDA ($A0),Y`, `LDA ($A7),Y` and `LDA ($88),Y` …
`LDA ($92),Y` in the kernel, because a computed pointer is invisible to static
analysis and `checkrom.py` cannot see it.

Miss one and the failure is not a wrong picture. A stray read of `$1E**`
corrupts a transaction in flight; a stray read of `$1D80-$1DEF` **switches the
bank out from under the running kernel** — and `$FD80-$FDEF` is 112 bytes of
live sprite data reached through exactly those pointers.

Tennis §2.5 is the nearest precedent and it is a mild one: its out-of-bounds
`LDA ($B2),Y` merely landed on a text plane. `make mailbox` is the gate, and it
has to run under `rig-play` rather than `det`, because the sprite pointers
advance with the score and a run where nobody scores never reaches the table
entries that matter.
