# Networked two-player Dodge 'Em on an Atari 2600, over FujiNet.
#
# Every target is a gate in the milestone ladder, and the order is the order
# they have to pass in: a rung that fails makes everything above it ambiguous.
#
#   make disasm       M0a DiStella over the dump, steered by tools/dodgem.cfg
#   make verify-org   M0b the split is the one descent finds, and it rebuilds
#                         to the cartridge byte for byte
#   make zp           M0c the zero-page census -- the gate that decides where
#                         the netcode's state can live at all
#   make echo         M1  the transaction latency, measured, before any porting
#   make dodgem       M2  the banked image, every changed byte declared
#   make ladder           all of it, in order
#
# Dodge 'Em is the first TRUE 4K game in this family and the first with NO
# free RAM. PORTING.md is the account; `make zp` is the measurement.

SHELL := /bin/bash
FUJI_FIRMWARE ?= $(HOME)/Workspace/fn-2600
VCS           ?= $(FUJI_FIRMWARE)/pico/atari-2600
SECS          ?= 30
DET_FRAMES    ?= 3000
FRAME_COUNT   ?= 1500
FRAME_COUNT_IN ?= 1800

.PHONY: all disasm verify-org defs zp phase anchors banks probe echo dodgem frames inputs slack stall det sim lobby session ladder clean

all: dodgem

# ---------------------------------------------------------------- M0a
# The disassembly itself. There is no published commented source for Dodge 'Em,
# so this project generates one: DiStella over the dump, steered by the
# code/data map in tools/dodgem.cfg. It is NOT checked in -- it is the game.
disasm:
	./build.sh disasm

# ---------------------------------------------------------------- M0b
# TWO claims, and only the second is a round trip.
#
# tools/checkmap.py walks the image by recursive descent from the reset vector
# and requires the declared code/data split to be the one it finds. That is not
# a formality: a run of data bytes disassembled as instructions re-encodes to
# exactly the bytes it came from, so the `cmp` cannot see a wrong split at all.
# Video Olympics' PORTING.md is the account of what that costs to discover the
# other way round.
verify-org:
	./build.sh verify-org

# ---------------------------------------------------------------- M0c
# The census, and the gate this port turns on. Dodge 'Em uses all 128 bytes of
# RAM, so "where does the netcode's state live" is the FIRST question and not a
# detail to settle once the transport works.
#
# It distinguishes SCRATCH (dead across the overscan band, so the network
# machine's working registers may live there) from PERSISTENT (never written by
# the game at all, so netcode state can outlive a frame there) -- and it is the
# persistent number that decides whether this port needs cartridge-side work.
# Expected to FAIL until the escalation in PORTING.md lands.
zp: verify-org
	./build.sh zp

# ---------------------------------------------------------------- M0d
# The bank map, COMPUTED. The tempting measurement is which address boundary
# the fewest branches cross; this is the one that matters, because a bank
# switch is a jump and everything between two switches -- every subroutine
# called, every table read -- has to be in one bank.
phase: verify-org
	./build.sh phase

# ---------------------------------------------------------------- M0e
# The 51 declared patch sites are where patches.py says they are. Anchored on
# addresses and opcodes rather than line numbers: rom/dodgem.asm is generated,
# so its line numbers move whenever tools/dodgem.cfg changes, and re-anchoring
# 51 sites by hand after every experiment is a cost with no benefit.
anchors: verify-org
	./build.sh anchors

# ---------------------------------------------------------------- M1
# What does one mailbox transaction cost, in video frames? Every latency
# number in this port hangs off that figure, and the family's rule is that it
# is MEASURED and not inherited -- the Intellivision ports believed a
# documented 30 Hz tick for years when it was 10.
#
# `make echo` needs a fujinet-pc and tools/latency_probe_server.py. Until it
# has actually been run HERE, nothing may quote a constant from a sibling.
probe: build/probe.bin
build/probe.bin: src/probe.asm src/dmcore.inc src/dmdefs.inc src/fujinet.inc src/vcs.inc build.sh
	./build.sh probe

echo: probe
	SECS=$(SECS) test/run_probe.sh

# ---------------------------------------------------------------- M2a
# The carve. Packing each bank's regions makes every cross-bank REFERENCE an
# undefined symbol, so the assembler enumerates the seams rather than leaving
# them to be found at run time as a jump into the middle of a table. It says
# nothing about a region that simply runs off its end into another bank, so
# dmbanks.py checks for those separately.
banks: phase
	./build.sh banks

# ---------------------------------------------------------------- M2
# The image: 7 banks of 2K plus the fixed half, 16384 bytes. Structural only
# so far -- the game still reads its own console -- so a split build must play
# EXACTLY like stock, which is what `make det` is for.
dodgem:
	./build.sh

# ---------------------------------------------------------------- M2b
# The split build plays EXACTLY like the 1980 cartridge. Per-frame checksums
# of the sim state, compared -- and required to change, because a gate that
# only measures agreement will pass two machines agreeing about nothing.
#
# It samples on CXCLR, which Dodge 'Em strobes once a frame at $F249, not on
# MAME's frame notifier: the notifier fires at a fixed point in emulated TIME
# and two builds are not at the same point in their frame when it does.
det: dodgem
	test/run_det.sh $(DET_FRAMES)

# ---------------------------------------------------------------- M2a
# Every frame the same length, and the same length as STOCK -- through five
# bank switches a frame. The number is learned from stock, not written down.
frames: dodgem
	test/run_frames.sh $(FRAME_COUNT)

# ---------------------------------------------------------------- M3
# The game reads no console port: every SWCHA/SWCHB/INPT4/INPT5 read comes
# from the shim, plus one deliberate live read of the B/W switch, which is a
# local preference and not on the wire.
#
# It DRIVES the game -- SELECT twice into the two-player variation, RESET to
# start, both sticks moving -- because sixteen of the twenty-four sites sit
# behind `BIT $94 / BVC` and never execute in attract. The state reached is
# asserted; a gate that passes in attract passes on nothing.
inputs: dodgem
	test/run_inputs.sh $(FRAME_COUNT_IN)

# ---------------------------------------------------------------- M4a
# The band the netcode runs in has the room it assumes. Dodge 'Em arms TIM64T
# twice a frame, so the harness tells the two bands apart by the VALUE armed
# ($28 vblank, $23 overscan) rather than by reading a PC, which inside a tap
# is not the instruction's anyway.
slack: dodgem
	test/run_slack.sh $(FRAME_COUNT_IN)

# ---------------------------------------------------------------- M5a
# The relay protocol, with no emulator anywhere -- two simulated consoles
# against a fresh server. It runs in about a second, so it is the one to run
# after every edit to server/.
sim:
	python3 tools/dm_client_sim.py

# The Lobby registration contract, against a MOCK on an ephemeral port.
# NEVER production: this family has rewritten a machine-wide appkey by
# pointing a test at the real Lobby before now.
lobby:
	python3 tools/test_lobby_pub.py

# ---------------------------------------------------------------- M4
# A stalled frame stalls the SIMULATION and not the PICTURE. Built twice --
# once normally, once with DMSTALLT=1, which stalls every other tick with no
# network involved -- so this measures the mechanism the transport will rest
# on rather than the transport.
stall: dodgem
	test/run_stall.sh $(FRAME_COUNT_IN)

# ---------------------------------------------------------------- M5
# One console, a real socket, a real HELLO. It cannot pair -- that takes two --
# so what it proves is that the appkey fallback, the path buffer, the N: open
# and the handshake all work, which separates "the socket works" from "two
# consoles agree" and makes the second much cheaper to debug.
session: dodgem
	SECS=$(SECS) test/run_sess.sh

ladder: defs verify-org zp phase anchors banks probe dodgem frames inputs slack stall det sim lobby session

defs:
	./build.sh defs

clean:
	rm -f build/*.p build/*.lst build/*.bin build/*.inc build/*.asm
