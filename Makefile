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

.PHONY: all disasm verify-org defs zp phase anchors probe echo ladder clean

all: verify-org

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

ladder: defs verify-org zp phase anchors probe

defs:
	./build.sh defs

clean:
	rm -f build/*.p build/*.lst build/*.bin build/*.inc build/*.asm
