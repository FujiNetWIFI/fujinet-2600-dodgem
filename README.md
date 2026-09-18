# Networked two-player Dodge 'Em, on an Atari 2600

Atari's Dodge 'Em (1980), CX2637, by Carla Meninsky — two people playing it
across the network through a FujiNet cartridge, in delay-based input lockstep
over a relay.

```sh
make ladder       # every gate, in order
make verify-org   # stock Dodge 'Em, rebuilt from the disassembly, byte-identical
make zp           # the census: this game uses all 128 bytes of RAM
make echo         # what does a mailbox transaction cost, in frames?
make dodgem       # build/dodgem.bin, 16384 bytes
make frames       # every frame the length stock measures, through 4.27 bank switches
make det          # the patched build plays exactly like the 1980 ROM
make inputs       # the game no longer reads a console port at all
make stall        # a stalled frame stalls the simulation and not the picture
make sim          # the relay protocol, with no emulator anywhere
make session      # one console, a real socket, a real HELLO
make rig          # two consoles, one match, zero desyncs
make rig-repair   # break one on purpose; it has to notice, and it has to heal
make rig-frames   # the raster IN A MATCH -- make frames measures a console
                  #   with no opponent, where the netcode never runs at all
make rig-switch   # ...and the synthetic SWCHB MEANS what the game thinks:
                  #   RESET and SELECT high at idle, and reachable by a press

make play         # not a gate: two windows, paired, playing
make stop         # tear that down
```

`TVSTD=ntsc` (the default) or `TVSTD=pal`. `TVSTD=secam` is refused, and for
Combat's reason rather than Tennis's: Dodge 'Em draws **both** cars from one
colour table at `$FF2C` EOR'd against `$A6`, and tells them apart by
**luminance**. A SECAM TIA picks its eight colours from the hue nibble and
ignores luminance entirely, so both players would be driving identical cars
round the same track. The refusal lives in the build because a 2600 cannot
detect its own television at runtime — the ROM generates the video timing and
there is nothing to read — and the relay refuses a SECAM client to match.

**The cartridge is not in this repository.** Dodge 'Em is Atari's, 1980. This
is a patch and a server, not a place to redistribute it. Put your own dump in
`rom/dodgem.bin` — see [`rom/README.md`](rom/README.md) for the md5 the build
checks against. The generated disassembly is the game just as much as the dump
is, and is gitignored too.

`build.sh` needs Macroassembler AS (`asl`/`p2bin`, on `PATH` or in `~/asl`) and
the firmware tree at `$FUJI_FIRMWARE` (default `~/Workspace/fn-2600`, on the
`2600-experiment` branch). `run.sh` needs a MAME with
`pico/atari-2600/emu/apply.sh` applied, and anything touching the network needs
a `fujinet-pc`.

## How it plays

Each console runs its own copy. The FujiNet Lobby lists the room; picking it
writes the relay's URL to an appkey and boots the ROM, which opens
`N:TCP://host:9603/`, says HELLO, and waits. The relay pairs the first two
consoles and tells each its role. With no Lobby key the ROM falls back to the
endpoint baked in at build time; with no relay at all it is simply Dodge 'Em.

**Only variation 3 is a match.** SELECT walks `$94`'s mode bits `00 → 80 → C0`,
and only the last gives the second player a car to drive: the players alternate
who drives the dot-collecting car, and whoever is *not* dodging drives the
chase car against them. Both people are busy at all times and the roles swap
every round, which is what makes this a better networked game than it looks.

SELECT walks `$96`'s level bits in the same breath, so the variation is a
**pair** and both are on the wire. RESET and SELECT are ANDed across the two
consoles, so either player may press either and both machines act on the same
tick. Black-and-white stays **local** — each player keeps their own setting,
and it is deliberately not on the wire.

## What made this one hard

Two things, and both are firsts for this family of ports.

**Dodge 'Em uses all 128 bytes of RAM.** Not nearly all — all. `make zp` is the
census: 121 cells in the game, 6 under the stack, 1 spare. Tennis had 26–32
free bytes to build its netcode in. So sixteen bytes of the *game* were evicted
into a cartridge text plane, which needed a new blit transform in the
cartridge firmware (`FN_BLIT_POKE`) because the planes had no console→plane
byte store at all.

**It is a true 4K game whose data sits on mailbox pages.** All four siblings
were 2K games that fit one bank. Dodge 'Em's tables occupy `$FD62-$FF33`, which
rebased into the window is the control page, the write-only TX stream and the
status page — including 112 bytes of live sprite data that lands exactly on the
**bank-switch hotspots**. Every one of them had to move, and the twelve
hardcoded pointer high bytes with them.

[`PORTING.md`](PORTING.md) is the full account, including the three gates that
passed on nothing before they were made honest, and the four bugs `make det`
found that nothing static could.
