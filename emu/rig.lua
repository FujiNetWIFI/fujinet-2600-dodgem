-- rig.lua -- what a console has to say for itself at the end of a match.
--
-- The verdict test/run_rig.sh reads, plus the scripted switch presses that make
-- the match worth judging. Deliberately built out of cells the ROM maintains
-- anyway rather than anything decoded off the screen.
--
-- Two rules this harness exists to obey, both learned the hard way:
--
--   * INPUT IS DRIVEN FROM A FRAME NOTIFIER, NEVER FROM A MEMORY TAP.
--     set_value called inside install_write_tap is silently lost -- the tap runs
--     in the CPU's execution context and port state settles at frame boundaries
--     -- so the raw port never changes and nothing reports an error. Both
--     consoles then agree perfectly about a switch neither ever saw pressed.
--   * THE FIELD OBJECTS ARE CACHED ONCE. A field looked up through
--     manager.machine.ioport.ports at the moment of pressing it is a fresh
--     wrapper, and set_value on a fresh wrapper does nothing either.

-- Keep in step with src/vodefs.inc. These are not Combat's addresses and
-- nothing but this comment will tell you if they drift.
-- THE NETCODE'S CELLS COME FROM THE BUILD, not from this file.
--
-- This harness arrived from a sibling with its addresses written in, and a
-- rename turned the comment above them into a claim that they were Dodge 'Em's
-- when every one was Tennis's. That is the exact shape of the bug that had
-- emu/latency.lua reporting nought rounds while 588 completed: a harness and a
-- ROM disagreeing in silence, with the harness reporting the quiet answer.
local SYM = dofile(os.getenv("DMSYMS") or "build/dmsyms.lua")
local DMENT, DMTICK, DMNST = SYM.DMENT, SYM.DMTICK, SYM.DMNST
local DMERR, DMRWAT, DMCRCV = SYM.DMERR, SYM.DMRWAT, SYM.DMCRCV
local DMSWA, DMSWB = SYM.DMSWA, SYM.DMSWB
local DMRING, DMLOC = SYM.DMRIN0, SYM.DMLOC0
local DMTRIG = SYM.DMTR4

-- The game's own cells, which are Dodge 'Em's and not the netcode's:
--
--   $82  the frame counter, stepped at $F4E0 -- INSIDE the stall gate, so it
--        moves on the ticks that ran and stands in for Combat's CLOCK.
--   $94  the mode bits SELECT walks, 00 -> 80 -> C0. A match pins them at C0.
--   $96  the level, which SELECT walks IN THE SAME BREATH ($58/$88/$B8). Two
--        consoles agreeing about $94 and not $96 are playing different games,
--        so the rig watches both -- see PORTING.md 6.1.
local CLOCK = 0x82
local VARIATION = 0x94
local LEVEL = 0x96

local SNAPTICK = tonumber(os.getenv("SNAPTICK") or "150")

local sp = manager.machine.devices[":maincpu"].spaces["program"]

local swb = manager.machine.ioport.ports[":SWB"]
local SW = { ["Reset Game"]  = swb and swb.fields["Reset Game"],
             ["Select Game"] = swb and swb.fields["Select Game"] }
local function switch(name, on)
    local f = SW[name]
    if f then f:set_value(on and 1 or 0) end   -- 1 IS a press, switches included
end

local frames, stalls, ticks = 0, 0, 0
local lastclock, lasttick, held, snap, snaploc = nil, nil, nil, nil, nil

-- EVERY CELL A TAP CLOSES OVER IS DECLARED HERE, ABOVE EVERY TAP.
--
-- Lua binds a local at the point of its `local` statement, so a table declared
-- BELOW a closure that uses it is not the same variable: inside the closure the
-- name is a global, and a global is nil. `#phase` on nil raises, the tap dies
-- on its first frame with nothing printed, and everything that tap was going to
-- do -- here, taking the snapshot -- silently never happens. The rig then
-- reported "SNAP never reached the snapshot tick" and two verdict lines failed
-- VACUOUSLY, which reads exactly like a desync and is not one.
--
-- `firstsel` had the same shape with a quieter ending: the tap assigned a
-- GLOBAL of that name, the `local` below shadowed it for the report, and the
-- report printed "never" for a press that had plainly happened.
local dbn, phase, bin = {}, {}, {}
local firstsel = nil

-- THE DIAGNOSTICS TIMESTAMP THEMSELVES FROM THE ROM'S OWN CELL, not from the
-- extended counter below. `ticks` is refreshed once per video frame by the frame
-- notifier, and the two consoles are not in wall-clock lockstep -- only in
-- SIMULATION lockstep -- so a write that happens mid-frame on both machines can
-- be stamped one apart purely by where each notifier last ran. That artefact
-- showed up as a one-tick wobble in the variation trace on two consoles whose
-- zero page was byte-identical, which is the most misleading thing a diagnostic
-- can do. DMTICK read at the instant of the write is exact and agrees.
--
-- The extended counter keeps its job: it drives the SCHEDULE, where what is
-- wanted is elapsed time on this machine and a value that does not wrap.
local function rawtick() return sp:readv_u8(DMTICK) end

-- The schedule is written in EXTENDED ticks. DMTICK is eight bits and wraps
-- every seventeen seconds, so a window written in raw ticks fires again on
-- every lap -- RESET restarting the game and SELECT walking the variation
-- onwards for the whole run, which is not what "press it once" means.
_G._rg_drive = emu.add_machine_frame_notifier(function()
    local raw = sp:readv_u8(DMTICK)
    if lasttick == nil then ticks = raw
    elseif raw ~= lasttick then ticks = ticks + ((raw - lasttick) & 0xFF) end
    lasttick = raw

    -- RESET starts a game; SELECT steps the variation. Pressed on BOTH consoles
    -- at the same TICK, which is the same simulated moment even though it is
    -- never the same instant: the switches are ANDed on the wire, so either
    -- player may press them and the pair must agree about the result.
    -- PRESSED ON ONE CONSOLE ONLY, which is what a person does and what the
    -- rig had never done. With both consoles pressing, the AND on the wire is
    -- trivially "pressed" whatever happens to either byte; with one pressing,
    -- the result depends on that console's record reaching the peer for exactly
    -- the right tick. The host is chosen by DMENT's role bit.
    -- Only once the match has started: before it, DMENT is zero on BOTH
    -- consoles and the role bit is clear, so both would think they were the
    -- host and both would press.
    local ent = sp:readv_u8(DMENT)
    local in_match = (ent & 0x02) ~= 0
    local iam_host = in_match and (ent & 0x04) == 0

    -- RIG_HOLD=select: stay in attract mode and HOLD SELECT for a long time.
    -- That is the case a human found and no scheduled tap-and-release ever did:
    -- Combat re-arms its SELECT debounce roughly once a second, so a held
    -- switch walks the variation onwards, and any difference in how often the
    -- two consoles re-arm shows up as two machines playing different games.
    -- SELECT FIRST, THEN RESET. SELECT only works between games now -- it is
    -- masked while GameOn's bit 7 is set -- so a schedule that started the game
    -- and then pressed SELECT would be asserting that a deliberate no-op does
    -- nothing, which is not the same as testing it.
    local want = nil
    if not iam_host then
        -- the guest presses nothing at all
    elseif os.getenv("RIG_HOLD") == "select" then
        if ticks >= 30 and ticks < 400 then want = "Select Game" end
    elseif os.getenv("RIG_HOLD") == "serve" then
        -- RIG_HOLD=serve: RESET over and over, which is Dodge 'Em's analogue of
        -- Dragster's rig-stage. Every press runs the game's own clear from
        -- $85 -- `LDX #$85 / JMP LF004` at $F1A9 -- and that loop used to run
        -- all the way to $FF through a `STY $00,X` that wraps inside page
        -- zero. It is bounded at $D6 now, and tools/check_zp.py proves the
        -- bound is a symbol rather than a literal; THIS proves it holds while
        -- two consoles are actually playing, hundreds of times over.
        --
        -- A press every sixteen ticks, held for four: long enough for the
        -- ANDed switch to reach both machines through the delay ring, short
        -- enough that the game restarts rather than sitting held.
        if ticks >= 30 and (ticks % 16) < 4 then want = "Reset Game" end
    elseif ticks >= 30 and ticks < 70 then want = "Select Game"
    elseif ticks >= 90 and ticks < 100 then want = "Reset Game" end
    if want ~= held then
        if held then switch(held, false) end
        if want then switch(want, true) end
        held = want
    end
end)

-- SAMPLED AT THE TIMER ARM, NOT AT CXCLR.
--
-- The sibling ports sample at $F224's `STA CXCLR`, once a frame, after the
-- logic and before the picture. TENNIS NEVER STROBES CXCLR -- it never touches
-- a collision register at all, which is the same fact that makes a stalled
-- frame free -- so a tap there fires only when the RAM clear sweeps the TIA on
-- its way past, which is once per RESET and not once per frame.
--
-- That is not a gate that fails; it is a gate that passes on nothing. The
-- snapshot was never taken, so `SNAP` printed "never reached the snapshot
-- tick" on BOTH consoles, and "the two consoles agree byte for byte" compared
-- those two identical sentences and said ok. PORTING.md 4.22, in a new
-- disguise: a diagnostic that has never once printed a value is a broken
-- diagnostic, not evidence.
--
-- $F1A2's `STY TIM64T` is the landmark Dodge 'Em does have: exactly once per
-- frame, in the RIOT at $0296 where no clear can reach it, after the picture
-- and after DMFCNT has moved the frame counter. The phase read here is the one
-- DMSHIM set earlier in the same pass.
_G._rg = sp:install_write_tap(0x0296, 0x0296, "tim64t", function(off, data, mask)
    frames = frames + 1
    -- CLOCK counts frames in which the sim ADVANCED, so a frame where it does
    -- not move is a stall and needs no cell of its own.
    local c = sp:readv_u8(CLOCK)
    if lastclock ~= nil and c == lastclock then stalls = stalls + 1 end
    lastclock = c

    -- FRAME-EXACT, not merely tick-exact. A tick is four frames and Combat's
    -- logic runs on every one of them, so "at tick 120" names four different
    -- states, and comparing two consoles at the wrong three of them looks
    -- exactly like a desync while the relay verifies sixty thousand checksums
    -- without a single mismatch.
    --
    -- THE PHASE COMES FROM DMENT, NOT FROM CLOCK. It used to be `CLOCK & 3`,
    -- and that is the same bug the ROM had: ClrGam clears $82-$A2 and CLOCK is
    -- $86, so every SELECT advance re-phases it. DMENT's bits 6-7 are stepped
    -- by DMPHI once per frame and there is no instruction anywhere in Combat
    -- that writes them. DMSHIM steps the phase on its way out, so the boundary
    -- frame -- the one that advanced the tick, sampled the checksum and
    -- captured the input -- reads $40 here, at CXCLR, near the end of it.
    local ph = sp:readv_u8(DMENT) & 0xC0
    if #phase < 12 and ph == 0x40 and ticks % 24 == 0
       and (phase[#phase] or ""):match("^t%d+") ~= ("t" .. ticks) then
        phase[#phase + 1] = string.format("t%d:c%d", ticks, c)
    end
    if snap == nil and sp:readv_u8(DMTICK) >= SNAPTICK and ph == 0x40 then
        local b = {}
        -- THE SIMULATION, and only it. The variation first, because two
        -- consoles playing different games agree about everything else until
        -- something moves them apart. Then the frame counter that paces the
        -- serve, the scores, the decoded variation flags, the dispatch group
        -- and the positions.
        --
        -- WHAT IS IN HERE IS WHAT DMCRC COVERS, and for the same reasons.
        -- The variation, the two-humans flag and the end swap first, because
        -- two consoles that disagree about any of the three draw visibly
        -- different games while agreeing about every coordinate. Then the
        -- ball's three 16-bit axes and their fractions, both players'
        -- positions, the serve state, the scores and the match state.
        --
        -- The shadows are NOT here. DMSWA, DMSWB and DMTRIG are what the
        -- netcode FILLS from the wire, not state the simulation owns, and a
        -- cell the netcode writes is not a cell the netcode should check.
        for _, a in ipairs({0x80, 0x81, 0xD0, 0x84,
                            0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91,
                            0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
                            0x98, 0x99, 0x9A, 0x9B,
                            0xA0, 0xB4, 0xC5, 0xC6, 0xC7, 0xC8,
                            0xCA, 0xCB, 0xCC, 0xD1, 0xD2}) do
            b[#b + 1] = string.format("%02X", sp:readv_u8(a))
        end
        -- WHAT THE TWO CONSOLES MUST AGREE ABOUT, AND WHAT THEY MUST NOT.
        --
        -- `SNAP` carries the simulation and nothing else: the tick, the
        -- checksum, the MIXED stick and switch bytes the game actually reads,
        -- and the zero page. Every one of those is a quantity both machines
        -- compute from the same inputs, so the verdict compares the line whole.
        --
        -- `LOCAL` carries the furniture, and it is reported precisely BECAUSE
        -- it differs. `hw` is this console's raw SWCHB -- with SELECT held on
        -- the host and not on the guest, $2D against $2F is the press working.
        -- `ring` is the slot holding the PEER's record, which is the other
        -- console's furniture and is the opposite byte by construction. Folding
        -- those into the compared line made a held switch look like a desync on
        -- two machines whose zero page was identical to the byte: the gate was
        -- asserting that the two players had their hands in the same place.
        snap = string.format(
            "SNAP tick=%d crc=$%02X swa=$%02X swb=$%02X : %s",
            sp:readv_u8(DMTICK), sp:readv_u8(DMCRCV), sp:readv_u8(DMSWA),
            sp:readv_u8(DMSWB), table.concat(b, " "))
        snaploc = string.format("LOCAL ring=$%02X hw=$%02X",
            sp:readv_u8(DMRING), sp:readv_u8(0x0282))
    end
end)

-- Every distinct value the switch shadow and the raw port ever took, so "the
-- press never happened" is distinguishable from "the press happened and the
-- console ignored it".
local swseen, hwseen = {}, {}
_G._rg_sw = sp:install_write_tap(DMSWB, DMSWB, "voswb", function(off, data, mask)
    swseen[data] = (swseen[data] or 0) + 1
    -- Only once the match is running. DMSWB is zero out of the RAM clear and a
    -- zero byte has bit 1 clear, so a boot-time reading of this shadow reports
    -- "SELECT pressed at tick 0" on every run and means nothing at all.
    if firstsel == nil and (data & 0x02) == 0
       and (sp:readv_u8(DMENT) & 0x02) ~= 0 then
        firstsel = string.format("tick=%d clock=%d", rawtick(), sp:readv_u8(CLOCK))
    end
end)
_G._rg_hw = sp:install_read_tap(0x0282, 0x0282, "swchb", function(off, data, mask)
    hwseen[data] = (hwseen[data] or 0) + 1
end)

-- Every advance of the variation, with the tick and the sim clock it happened
-- at. Two consoles that walk the variation at different rates differ HERE
-- first, and the tick tells us whether they parted company at a boundary.
-- The tick at which SELECT first READS as pressed, and the CLOCK it had then.
-- If the two consoles differ here the wire delivered the press at different
-- ticks; if they agree, the divergence is in CLOCK and not in the input.
-- 4*ticks - CLOCK should be a constant on both consoles: CLOCK counts frames in
-- which the sim advanced and there are four of those per tick. ClrGam zeroes
-- CLOCK on every SELECT advance, which re-phases it -- and if the re-phasing
-- lands differently on the two machines, the tick and the clock decouple.
-- SelDbnce ($89) is Combat's SELECT debounce: set to $FF after an advance and
-- cleared once every 64 CLOCKs. Anything else that clears it lets a held SELECT
-- advance again immediately -- which is exactly the symptom.
_G._rg_bin = sp:install_write_tap(VARIATION, VARIATION, "variation", function(off, data, mask)
    -- Keep the LAST forty, not the first: the two consoles agree for a long
    -- time and part company somewhere in the middle of a long hold.
    -- Keep the FIRST twelve: if the two consoles part company at the very
    -- first advance the phase is set there and everything after is consequence.
    if #bin < 12 then
        bin[#bin + 1] = string.format("t%d:%d@c%d", rawtick(), data, sp:readv_u8(CLOCK))
    end
end)

_G._rg_dbn = sp:install_write_tap(0xA3, 0xA3, "seldbnce", function(off, data, mask)
    if #dbn < 24 then
        dbn[#dbn + 1] = string.format("t%d:$%02X@c%d", rawtick(), data, sp:readv_u8(CLOCK))
    end
end)

local function tally(t)
    local k = {}
    for v in pairs(t) do k[#k + 1] = v end
    table.sort(k)
    local o = {}
    for _, v in ipairs(k) do o[#o + 1] = string.format("$%02X:%d", v, t[v]) end
    return table.concat(o, " ")
end

_G._rg_stop = emu.add_machine_stop_notifier(function()
    print(string.format(
        "RIG tick=%d err=$%02X state=%d ent=$%02X rwat=%d frames=%d stalls=%d",
        ticks, sp:readv_u8(DMERR), sp:readv_u8(DMNST), sp:readv_u8(DMENT),
        sp:readv_u8(DMRWAT), frames, stalls))
    print("SWB SHADOW EVER HELD " .. tally(swseen))
    print("SWCHB RAW EVER READ " .. tally(hwseen))
    print(snap or "SNAP never reached the snapshot tick")
    print(snaploc or "LOCAL never")
    print("FIRSTSEL " .. (firstsel or "never"))
    print("BINVAR " .. table.concat(bin, " "))
    print("SELDBNCE " .. table.concat(dbn, " "))
end)
