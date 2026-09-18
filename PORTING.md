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

---

## 5. The escalation, and what it actually needed

`make zp` failed by 15 cells, so the escalation fired. Two things about it are
worth writing down, because the obvious version of it does not work.

### 5.1 There was no way to write a text plane

The planes at `$1800-$1AFF` are the only cartridge memory a 2600 client can
both write and **read back** (`lda $1800,y`), which makes them the only place a
console out of RAM can keep a variable. But before this port, **the console
could not put a byte there.** The write paths were `FN_HOT_TROW`/`TCHR`/`TEND`,
which render *glyphs*, and the blit port, whose source is the reply window —
server data, not console data. Neither can store a byte the console computed.

The routes that avoid new firmware were all tried on paper first:

- **Compose the input byte on the relay.** Refused: it makes the console
  depend on the network for *its own stick*, and Combat §4.13's rule is that a
  cartridge with no server is still a Dodge 'Em cartridge.
- **Round-trip the state through the relay** and `FN_BLIT_RAW` it back out of
  the reply window into a plane. This works, and for state that changes a few
  times a minute it is the right answer with no firmware change at all. It does
  not work for the dot bitmap, which changes whenever a dot is eaten.
- **Keep state in the path buffers**, read back with `FN_BLIT_PATH`. The
  buffers are write-only and the blit renders glyphs, so recovering a byte
  needs the font to be injective over 0-255. It is not; `fuji_mailbox.h`
  records three glyph pairs that were bit-identical and had to be redrawn.
- **Store bytes as hex digit pairs** and decode the plane bits back. The
  sixteen hex glyphs *are* distinguishable, so this one works — and costs a
  blit to write and five scanlines of bit-decoding to read, per byte, per
  frame. Fine for a cold value; impossible for a tick.

So one new transform was added to the cartridge firmware:

```c
#define FN_BLIT_POKE     14       /* plane[dst] = the low byte of src        */
```

It composes nothing, which is the point. It is bounded to the planes rather
than to the window — a client that could reach `$1B00` or `$1F00` would corrupt
the mailbox it is talking through, and the symptom would be a failed
transaction rather than a wrong picture, so `test_render.c` checks the bound
rather than assuming it. Both failure modes were confirmed to fail the test
before the implementation was restored.

### 5.2 Which sixteen bytes move, and why not the ones first proposed

The first proposal was the six playfield streams `$C3-$F8`, on the grounds that
54 bytes is generous. The census says that is the worst possible choice: the
**kernel** reads those six streams twice per scanline pair at exact cycle
positions, so relocating them puts a plane read in the tightest budget in the
game for no benefit beyond headroom.

What moved instead, chosen off the phase columns:

| block | bytes | read in | written |
|---|---|---|---|
| `$AC-$B4` | 9 | **vblank only** — never by the kernel | four EOR sites, only when a dot is eaten |
| `$BC-$C2` | 7 | **overscan only** | `LF5A0`'s swap, at a round end |

Sixteen bytes, neither on the kernel path, both written at frequencies measured
in events per second rather than per frame. With `$F9` that is 17 cells against
a need of 12-13, which clears the *"need plus two"* margin a port should
insist on: one that fits exactly has no room for the cell the next bug needs.

**The rule:** *choose what to evict by how often it is written and who reads
it, not by how big it is.*

---

## 6. Three things the ROM does that the plan did not expect

### 6.1 SELECT walks TWO quantities, so the whitelist must pin both

`$F162` advances `$94` bits 7,6 through `00 → 80 → C0 → 00` — the three game
variations — and in the same breath advances `$96 & $F8` through
`$58 → $88 → $B8 → $58`:

```
LF186: STA  $94
       LDX  #$1E / STX $86
       LDA  $96 / AND #$F8 / CMP #$B8
       BNE  LF198
       LDA  #$58 / BNE LF19B
LF198: CLC / ADC #$30
LF19B: STA  $96
```

So "mode 11" is `$94` bits 7,6 = `11` **and** `$96 & $F8 = $B8`, and a
whitelist that pins only `$94` leaves two consoles agreeing about the variation
while playing different levels. Both go in the checksum. Combat §4.21 is the
rule — *the checksum must cover every cell that selects behaviour* — and this
is the cell that is easy to miss because nothing about `$96` looks like a mode.

### 6.2 `$9F` carries the black-and-white switch, and must stay OUT

`$9F` is dual-purpose and the two purposes look nothing alike. Vblank writes a
colour mask derived from `SWCHB` bit 3:

```
LF0F5: LDA SWCHB / LDX #$07 / LDY #$07
       AND #$08 / BEQ LF104
       LDX #$F7 / LDY #$03
LF104: ... STX $9F          ; $07 in colour, $F7 in black-and-white
```

and the four turn points read it as a game-logic flag, `LDX $9F / BNE`. Both
values are non-zero, so **behaviour is identical** — but two consoles with
different B/W settings hold different bytes there for the whole frame.

Put `$9F` in the checksum and the rig reports a desync between two machines
that agree about everything. Video Olympics §3.15 in a new place: *a cell the
netcode fills is not state the netcode should check* — and its converse, a cell
the PLAYER's furniture fills is not state either. Black-and-white stays local,
like Dragster's.

### 6.3 The bank split has to be by phase, not by address

§3's branch-clean split at `$F5A0`/`$FC48` is necessary and **not sufficient**,
and this is the correction that matters most for the build. A bank switch is a
jump, so everything that runs between two switches must be in one bank —
including every subroutine the phase calls. Minimising *branches* across an
address boundary says nothing about that; 18 cross-bank `JSR`s would mean 18
switches a frame, not two.

The right measurement is the transitive footprint of each frame phase, code
plus every table it actually reads:

| phase | code | data | total |
|---|---|---|---|
| A — VSYNC + vblank band, `$F0E4-$F243` | 1952 | 194 | **2146** |
| B — kernel, `$F249-$F41F` | 471 | 264 | **735** |
| C — overscan band, `$F420-$F4E9` | 1281 | 152 | **1433** |
| D — cold, `$F0CA-$F0E3` | 315 | 128 | **443** |

with **A∩B = 0 and B∩C = 0** — the kernel shares nothing with either band, the
cleanest seam in the game. A alone is 2146, 98 bytes over a bank, and splits at
its one natural fissure (`$F228 JSR LF859`, the whole dot engine).

That gives four game banks, not two, and **four bank switches a frame**, each
placed where the stack is empty and the cost is absorbed: `$F228` inside the
vblank timer, `$F244` in front of `STA CXCLR / STA WSYNC`, `$F420` in front of
the `STA WSYNC` at `$F422`, `$F4EA` in front of `$F0E8`'s.

*Worth doing early in the next port:* compute each phase's transitive footprint
and the pairwise overlaps before choosing any boundary. The address-space
answer and the phase answer are different questions, and only the second one
builds.

---

## 7. M1: what a transaction costs, measured here

```
FRAMES 1177  ROUNDS 391  ERR $00
OPEN    n=1     mean=1.00 min=1 max=1
WRITE   n=392   mean=1.00 min=1 max=1
STATUS  n=392   mean=1.00 min=1 max=1
READ    n=391   mean=1.00 min=1 max=1
TICK 3.0 frames for WRITE+STATUS+READ = 20.0 Hz
```

One frame per transaction, three frames per lockstep tick, 20 Hz — the same
figure Combat and Video Olympics measured, and `min = max = 1` on every step,
so it is not a mean hiding jitter.

That is the number `DMK EQU 4` is chosen against: a 4-frame tick is 15 Hz
against a 20 Hz transport, so the transport has room and a tick that misses is
a stall rather than a permanent deficit. The family's rule is that this is
MEASURED and never inherited — the Intellivision ports believed a documented
30 Hz tick for years when it was 10 — and Dragster makes its `make echo` exit 1
rather than quote a sibling's constant. This one has now actually been run.

### 7.1 A harness and a ROM can disagree in silence, in both directions

The first run reported `ROUNDS 0` while the echo server, independently,
reported **588 rounds, 588 bytes, 51.00 ms mean inter-arrival**. Nothing was
wrong with either. `emu/latency.lua` arrived from a sibling carrying

```lua
local VOST, VOERR, VOFCNT = 0xF7, 0xD5, 0xFA
```

and a comment saying to keep those in step with the assembly by hand. This port
had moved the probe's counters off the top of RAM — a probe that puts its
counters under the stack is measuring how deep it nested — and the harness went
on tapping three cells that no longer meant anything.

Both halves of that are worth keeping. The harness reported a plausible,
quiet, *wrong* answer rather than an error; and the only reason it was caught
at all is that a second, independent observer — the echo server on the far end
of the socket — was counting the same thing a different way.

*The rule:* **a harness that taps a ROM by address must take the addresses FROM
the ROM.** `tools/mksyms.py` now reads them out of the assembler's listing and
writes the Lua table `emu/latency.lua` loads. And `DMSYMS` is passed as an
ABSOLUTE path, because MAME has to be run from its own tree or
`-autoboot_script` is silently ignored, so every relative path a harness opens
resolves against MAME's directory and not the project's.

*Also worth having two of:* the echo server's independent count is what turned
a silent zero into a diagnosis. A gate that measures one thing one way cannot
tell you it is measuring the wrong cell.

### 7.2 Observed, not caused by this port

`fujinet-pc` segfaults during its own shutdown — after `All devices shut down`,
in `NetworkProtocolTCP::dtor` — every time the rig sends it TERM. It happens
after the measurement is complete and does not affect the numbers, and it
reproduces with the stock distribution in `build/rig/fn1`, so it is recorded
here rather than worked around.

---

## 8. The structural port, and what each gate cost to make honest

M0 through M4a are done: the split build is byte-identical to the 1980
cartridge over 3000 frames, its frames are the same length as stock's, it
reads no console port, and both timed bands have room left.

```
make defs        53 equates agree with fuji_mailbox.h
make verify-org  byte-identical (4096 bytes); the split is the one descent finds
make zp          the census -- 121 cells used, 1 free, stack floor $FA
make phase       four game banks, computed from the frame phases
make anchors     74 declared sites, every one an instruction boundary
make banks       every bank fits; 5 seams, 2 of them fall-through
make probe       build/probe.bin -- 559 bytes, checkrom clean
make dodgem      build/dodgem.bin -- 16384 bytes, checkrom clean
make frames      900 frames, every one 262 lines, the same as stock
make inputs      every console-port read comes from the shim
make slack       neither band exhausted; worst frame leaves 10 ticks
make det         3000 frames byte-identical, 2840 distinct states
```

### 8.1 The measurements the netcode is built on

| | |
|---|---|
| transaction cost | 1 frame per step, **3 frames per round, 20.0 Hz** (§7) |
| frame | 262 lines, **4.27 bank switches per frame** |
| vblank band slack | mean 27.5 ticks, **worst 10**, never exhausted |
| overscan band slack | mean 30.6 ticks, **worst 10**, never exhausted |
| `DMGATE` | 8 ticks = 512 cycles of guaranteed headroom per step |

A tick is `DMK = 4` frames, so 15 Hz against a 20 Hz transport: the transport
has room, and a tick that misses is a stall rather than a permanent deficit.

### 8.2 Three gates that passed on nothing first

This is the section to read before writing the next one. Every one of these
looked like a working gate.

**`make inputs` passed with a patch deliberately removed.** Sixteen of the
twenty-four read sites are the four turn-decision points, each behind
`BIT $94 / BVC` — they execute only in the variation where a human drives the
chase car, and attract does not run it. Even STOCK reads two of its
twenty-four sites in attract. The gate now drives SELECT twice, RESET, and
both sticks, and **asserts the state it reached**: `$94` must show `$Cx` and
`$95` bit 7 must have been set. With that, the same removal produces a read
from outside the shim — twice in 1800 frames, which is also a fair measure of
how thin the coverage still is.

**`make frames` printed nothing at all.** The harness came from a sibling
ending in `add_machine_stop_notifier`, which never fires in this MAME. It
measured everything correctly and emitted no output, and a gate whose output
is empty cannot fail. `run_frames.sh` now treats a missing report as a failure.

**`emu/latency.lua` reported nought rounds while 588 completed** (§7.1) — the
cell addresses were hand-copied from a sibling and this port had moved them.
The echo server's independent count on the far end of the socket is what
turned a silent zero into a diagnosis.

*The rule the three share:* **a harness and the thing it measures can disagree
in silence, and the harness will report the quiet answer rather than an
error.** Drive the code you are judging, assert you reached it, take addresses
from the build, and treat no output as failure.

### 8.3 What `det` found that nothing static could

Four bugs, and three of them were the same mistake wearing different clothes:
a table-relative address written as a literal.

1. **The pointer HIGH bytes** — declared, and obvious once the tables moved.
2. **The pointer LOW bytes** — `LDA #$94` is a literal that says nothing about
   where the table is. Both halves are immediates and neither is wrong alone.
3. **The comparisons that TEST those pointers** — `CMP #$CA` is the digit
   table's end, `CMP #$8C` is where the crash animation's walk stops. The scan
   that finds these looks for `LDA <pointer cell>` followed by `CMP #imm`;
   every immediate in that shape is an address, not a number.
4. **A pointer built by 16-bit ARITHMETIC** across four instructions, which a
   sweep for `LDA #imm / STA zp` cannot see.

And one that was structural rather than arithmetic: **duplicated tables at
different addresses**. The digit pointers are built in G0 and dereferenced in
G2. `tools/check_pins.py` is the generalisation — every label in the pinned
span resolves to one address in every bank, checked in the symbol table before
linking, because `det` can only find that class by running long enough to
reach the event that follows the pointer. It took 291 frames to reach the
first car crash.

### 8.4 Where the two scanlines went

The split build measured 264 lines against stock's 262, on every frame.
`emu/seams.lua` records the scanline each bank switch lands on:

```
bank 1 at line   6.7     inside the vblank band      absorbed
bank 2 at line  14.6     inside the vblank band      absorbed
bank 3 at line 231.9     in front of $F424's WSYNC   absorbed
bank 0 at line 263.3     after the overscan spin     NOT absorbed
```

Two fixes. `DMMIX` ran from each bank's entry dispatcher, which is *before*
the band's timer is armed — so its cycles delayed the arm, delayed the spin,
and lengthened the frame. Moved inside the band, the spin swallows it. That
also needed `$F0F5`'s `SWCHB` read to go back to the live port, which is not a
concession: black-and-white is a local preference and is not on the wire.

The seam at 263.3 has no wait on its far side, so the overscan band is one
tick shorter and the switch fits in the room that makes. It costs 64 cycles of
slack in the band the netcode does not run in.

*The rule:* **work added before a timed band lengthens the frame; the same
work inside it is free.** Video Olympics §3.13 says it for work of varying
length; it is just as true of work that is always the same size.

---

## 9. The stall, and a gate that was measuring the attract screen

### 9.1 The primitive, proved before anything rests on it

A stall is a frame drawn normally with the game-logic chain skipped. Dodge 'Em
advances its simulation in two places, so there are two gates:

```
$F228  JSR LF859   the dot-and-scoring engine, in vblank -- folded into
                   DMTOG1, the bank switch that seam already needed
$F4C6  the movement chain, in overscan: LF5BF turns the cars, LF5A0 swaps
       the players' saved blocks, and $F4E0-$F4E9 step the frame counters
```

**The counters are inside the gate**, not outside it. Video Olympics §3.16 is
the rule: everything left ungated becomes a function of the local stall
pattern, and the stall pattern is the one thing two consoles differ in by
design, because absorbing it is what lockstep is *for*.

`DMADV` defaults to "advance" every frame and the gate clears it. That
direction is load-bearing: `DMADV` lives at `$C0`, which the cold clear sweeps
to zero along with the rest of the page, so a gate that only ever *cleared* it
would leave the console stalled from power-on — drawing a perfect still
picture of a game that never starts.

`make stall` builds the image twice, once with `DMSTALLT=1`, which stalls every
other tick with no network involved. It measures the mechanism rather than the
transport, and requires both halves:

```
the simulation advanced on 99.9% of frames normally, 69.2% when stalling
the picture: 261:1633 262:173 -- identical in both
```

### 9.2 `make frames` was measuring the attract screen

This is the third gate in this port to pass on the wrong workload, and it is
worth recording because it looked *more* convincing than the truth.

Measured in attract, Dodge 'Em runs a flat 262 lines and the gate asserted
"every frame the same length, and that length is stock's". Driven into a real
match it runs **261 and 262 mixed** — because the game itself varies, and
stock varies identically:

```
stock, driven:  LINES 261:1327 262:173
split, driven:  LINES 261:1327 262:173
```

So the flat 262 was a fact about the attract screen, and the assertion built on
it would have been satisfied by any build that also idled. The gate now
compares **the whole distribution** against stock's, which catches a frame the
netcode lengthened *and* one it shortened, without needing to know which
lengths the game is entitled to. Reverting the overscan timer patch shifts the
entire distribution up by one line and the gate says so.

*The rule, now three times over:* **drive the code you are judging, and assert
you reached it.** `make inputs` saw nine of twenty-four sites, `make frames`
measured an idle screen, `emu/latency.lua` tapped cells that had moved. Each
reported a clean, quiet, wrong answer.

---

## 10. The session, and four failures that all looked like silence

`make session` brings up one console, one `fujinet-pc` and a real relay, and
requires the relay to name the console:

```
127.0.0.1:51264 connected
127.0.0.1 is DODGEM (NTSC)
session: PASS
```

One console cannot pair — that takes two — so what this proves is the appkey
read, the fallback, the path buffer, the `N:` open and the handshake. It
separates "the socket works" from "two consoles agree", and the second is much
more expensive to debug.

Getting there cost four rounds, and every one of them presented as the same
thing: the relay log saying nothing at all.

### 10.1 The cold clear ate the session

The session spends a socket and a handshake filling the netcode's cells and
then hands the console to the game — at `$F0CA`, whose first act is
`LDX #$FF / TXS / INX / TXA / STA VSYNC,X / INX / BNE`, a sweep of `$00-$FF`
that clears the TIA and every byte of RAM. The harness reported
`ent=00 err=00 tick=00 nst=00`, which is exactly what a wiped netcode looks
like from the outside and is indistinguishable from one that never ran.

The answer is not to bound the game's clear — it is stock code and `det`
depends on it. It is to not run it on the path that has something to lose. The
boot bank does a **bounded** clear of its own (the TIA, and the game's cells,
and not the netcode's) and a networked handover enters G3 at a **second cold
entry past the sweep**. The un-networked path still goes through `$F0CA`
exactly as the cartridge does, which is what keeps `make det` meaningful.

### 10.2 A one-shot hotspot is not an arm-and-commit pair

`FH_PATHO` and `FH_PATHC` are in the bit-7-set half of the control page, which
is the ONE-SHOT half: the data comes from the store itself. The arm-then-commit
pair belongs to the registers below `$80`. Writing

```asm
        lda     #FP_SEL0
        sta     FNRSEL+FH_PATHO
        sta     FNCMT           ; <- wrong: commits whatever was armed last
```

is not a no-op with a wasted cycle. fujinet-pc logged `rs232_open()` and then
`ERROR: deviceSpec is empty`, and the relay never saw a connection.

### 10.3 "A = 0 on success" was true and useless

`CSAKGET` documents itself as returning zero on success, and on an appkey that
does not exist it returned zero anyway: fujinet-pc logs `fopen … err` and the
console sees a perfectly ordinary empty reply. The fallback to the build-time
endpoint never ran, and the devicespec stayed empty.

The fix is not a better convention. **The cartridge publishes the active path
buffer's length at `$1F17` and republishes it on every change**, so "is there a
devicespec" is a fact to be read rather than a return value to be trusted:

```asm
        jsr     CSAKGET
        lda     FNPLEN
        ora     FNPLEN+1
        bne     DMB2            ; something is in the buffer, whatever said so
        jsr     DMFALLB
```

### 10.4 The gate was grepping for the wrong evidence

With all three fixed, the console opened a socket, sent twelve bytes, and was
named — and `make session` still reported FAIL, because it grepped the relay
log for the word `HELLO`. The relay does not log the message name. It logs the
**result** of one: `is DODGEM (NTSC)`.

*The rule, and it is the same one as §8.2 from the other end:* **grep for the
evidence, not for the message.** A gate that looks for the name of a thing
rather than the trace it leaves will fail on a system that is working, and the
three real bugs above were found while chasing it.

### 10.5 What the harness reads

`emu/sess.lua` reads the netcode's own cells rather than the screen, with the
addresses generated from the assembler by `tools/mksyms.py` — for the reason
§7.1 gives. It also taps the path port directly, because
`pathchars=0 pathops=4 pathlen=0` is a diagnosis and "the relay saw nothing"
is not.
