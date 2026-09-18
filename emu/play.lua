-- play.lua -- the rig with its HANDS ON THE STICK.
--
-- emu/rig.lua presses RESET and SELECT and nothing else, and every gate it runs
-- is green. A person then started a game and the two consoles came apart inside
-- a couple of seconds, with the relay reporting thousands of mismatches it had
-- never reported in a rig run. PORTING.md 4.18 said a harness that presses
-- nothing proves nothing; this is the same lesson one notch further in. THE RIG
-- HAD NEVER MOVED A PADDLE, so the only inputs it ever exercised were the two
-- that are ANDed on the wire and identical on both machines by construction.
--
-- So this one plays. Each console drives its own LEFT port -- which is what a
-- player's hands do -- on a schedule that is DELIBERATELY DIFFERENT on the two
-- machines and deliberately NOT aligned to anything either console shares.
--
-- That asynchrony is not sloppiness, it is the property under test. A real
-- player's thumb has no idea what tick it is. The design's whole claim is that
-- it does not need to: each console captures its OWN stick whenever it likes,
-- stamps the capture with a tick, and the peer applies exactly the byte that
-- was sent. If asynchronous input can desync the pair, that is a bug in the
-- ROM and not an artefact of the harness -- which is the opposite of the
-- situation emu/det.lua is in, where two BUILDS have to see identical bytes.
--
-- It prints one line per tick of the authoritative sim state, sampled at the
-- one instant the two consoles are comparable, for tools/playdiff.py to line up
-- and diff. The point is not to know THAT they diverged -- the relay says that
-- already -- but WHICH CELL went first, and at which tick.

-- Keep in step with src/vodefs.inc.
-- GENERATED, not transcribed. This file arrived from a sibling with its cell
-- addresses AND ITS FLAG BITS written in: DME_NET is $02 in Tennis and $01
-- here, DME_ROLE $04 there and $02 here. A harness that reads the right cell
-- and the wrong bit reports a console that is not in a match and never was.
local SYM = dofile(os.getenv("DMSYMS") or "build/dmsyms.lua")
local DMENT, DMTICK, DMNST, DMERR = SYM.DMENT, SYM.DMTICK, SYM.DMNST, SYM.DMERR
local DMCRCV, DMSWA, DMSWB = SYM.DMCRCV, SYM.DMSWA, SYM.DMSWB
local DMRING, DMLOC, DMRWAT = SYM.DMRIN0, SYM.DMLOC0, SYM.DMRWAT
local DME_NET, DME_ROLE, DME_RSY = 0x01, 0x02, 0x10
-- $82 is Dodge 'Em's frame counter, stepped at $F4E0 INSIDE the stall gate,
-- so it moves on the ticks that ran.
local CLOCK = 0x82

local sp = manager.machine.devices[":maincpu"].spaces["program"]

-- CACHED ONCE: a field looked up at the moment of pressing it is a fresh
-- wrapper and set_value on it is lost.
local FIELDS = {}
local function field(k)
    if FIELDS[k] == nil then
        local tag, name = k:match("^(.-)|(.*)$")
        local p = manager.machine.ioport.ports[tag]
        FIELDS[k] = (p and p.fields[name]) or false
    end
    return FIELDS[k]
end

local held = {}
local function apply(want)
    for k in pairs(held) do
        if not want[k] then
            local f = field(k); if f then f:set_value(0) end
            held[k] = nil
        end
    end
    for k in pairs(want) do
        if not held[k] then
            local f = field(k); if f then f:set_value(1) end
            held[k] = true
        end
    end
end

local ticks, lasttick, frames = 0, nil, 0

-- THE LEFT PORT, ON BOTH CONSOLES, WHATEVER THE ROLE. Each player sits at
-- their own machine with one joystick in port 1; the role decides which PLAYER
-- the byte drives and that is settled by the swap in DMNET. A harness that put
-- the guest on port 2 would be right about nothing except the bit numbering.
local P1 = ":joyport1:joy:JOY"
local TRIG = P1 .. "|P1 Button 1"
local DIRS = { "P1 Left", "P1 Right", "P1 Up", "P1 Down" }

-- INPUT IS DRIVEN FROM A FRAME NOTIFIER, NEVER FROM A MEMORY TAP.
_G._pl_drive = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    local raw = sp:readv_u8(DMTICK)
    if lasttick == nil then ticks = raw
    elseif raw ~= lasttick then ticks = ticks + ((raw - lasttick) & 0xFF) end
    lasttick = raw

    local ent = sp:readv_u8(DMENT)
    local in_match = (ent & DME_NET) ~= 0
    local host = in_match and (ent & DME_ROLE) == 0

    local want = {}
    if not in_match then return end

    -- The host starts the game, once, the way a person would.
    if host and ticks >= 30 and ticks < 40 then
        want[":SWB|Reset Game"] = true
    end

    -- Then both players play. KEYED TO THE EMULATOR'S FRAME COUNTER, not to any
    -- tick: this is a hand, and a hand is asynchronous. The two consoles get
    -- different periods so the two players are never doing the same thing and
    -- a swap between them would show as plainly as a desync.
    --
    -- A joystick is four bits and there is nothing to smooth, so this is a
    -- schedule rather than a waveform: each console holds one direction for a
    -- while and then another, on periods that share no factor with the other
    -- console's, so the two players are never doing the same thing.
    --
    -- THE TRIGGER IS THE SERVE. `BIT $A0 / BPL` at $F363 demands a press only
    -- while a serve is pending, so a rally needs none and a match that never
    -- sees one never starts.
    if ticks >= 45 then
        local period = host and 53 or 37
        local phase  = host and 0 or 19
        want[P1 .. "|" .. DIRS[(((frames + phase) // period) % 4) + 1]] = true
        local b = host and (frames // 41) % 3 or (frames // 31) % 3
        if b == 0 then want[TRIG] = true end
    end
    apply(want)
end)

-- One line per tick, at the phase-0 frame -- the only instant at which two
-- consoles are comparable, and the same instant DMCRC is sampled at. The phase
-- comes from DMENT because CLOCK is a cell ClrGam rewrites.
--
-- THE LINE IS NUMBERED BY COUNTING BOUNDARIES HERE, not by the extended tick
-- the frame notifier maintains. This tap fires exactly once per tick, on the
-- frame that completed the boundary -- a stalled boundary leaves the phase at
-- zero and does not print -- so a count kept in the tap IS the tick, with no
-- wrap and no sampling error.
--
-- The notifier's counter is a video-frame sample of DMTICK, and two consoles in
-- simulation lockstep are not in wall-clock lockstep, so it labels a boundary
-- one out whenever the notifier last ran on the other side of it. Two lines
-- then collide on one number, one number goes missing, and the diff reports
-- every downstream cell as divergent: at the first "divergence" CLOCK differed
-- by EXACTLY FOUR, which is one tick of sim frames and the signature of a
-- mislabelled line rather than of a desync. Same lesson as the variation trace,
-- one file along: anything the harness measures with its own clock, it is
-- measuring wrong.
-- PLAY_WINDOW=lo,hi: every FRAME in that tick range, not every tick. A tick is
-- four frames and the thing being chased is a frame-count divergence, so the
-- per-tick dump can only ever say that one happened, never where.
local wlo, whi
do
    local w = os.getenv("PLAY_WINDOW")
    if w then wlo, whi = w:match("^(%d+),(%d+)$") end
    wlo, whi = tonumber(wlo or ""), tonumber(whi or "")
end

-- PLAY_INJECT=<tick>: deliberately corrupt this console's simulation at that
-- tick, on CONSOLE 1 ONLY (PLAY_INJECT is passed to one of them). One added to
-- TankY0 is the smallest desync there is -- one scanline -- and it is exactly
-- the kind a real one starts as.
--
-- This is the only way to test a REPAIR. Detection can be tested by waiting for
-- a bug; recovery cannot, because a correct pair never diverges. So the harness
-- has to break one on purpose, and then assert that the two consoles come back
-- together on their own.
local inject = tonumber(os.getenv("PLAY_INJECT") or "")
local lastinj = -1
local injected, was, injwatch = false, 0, 0
-- HELD FOR SEVERAL TICKS, not nudged once.
--
-- A single nudge was injected, appeared in exactly one dumped tick, and was
-- gone by the next -- overwritten by LF5A0's round-end swap before any tick
-- boundary sampled a checksum over it. The relay reported zero mismatches and
-- the two consoles "agreed", which is the VO 3.18 trap wearing new clothes:
-- the corruption healed itself and the gate would have called that a repair.
--
-- DMCRC samples once a tick, so the corruption has to outlive a boundary to
-- exist as far as the netcode is concerned. Ten ticks is comfortably more than
-- one and still far less than the repair takes.
local INJHOLD = 10

-- THE REPAIR PATH, STEP BY STEP. Recovery took 8 ticks in one run and 232 in
-- another, and "it came back eventually" is not a diagnosis. These three taps
-- say which of the four steps is slow: the mismatch being NOTICED (DME_RSY
-- goes up), the press being MADE (DME_RSY comes down, in DMCAP), the press
-- reaching the game's own switch shadow, and the game acting on it.
local rsy = false
_G._pl_rsy = sp:install_write_tap(DMENT, DMENT, "voent", function(off, data, mask)
    local now = (data & DME_RSY) ~= 0
    if now ~= rsy then
        rsy = now
        print(string.format("RSY %s t%d raw%d ph%02X",
            now and "ARMED" or "PRESSED", ticks, sp:readv_u8(DMTICK),
            sp:readv_u8(DMENT) & 0xC0))
    end
end)

-- The mixed switch byte the game actually reads. Bit 0 is RESET, active low,
-- so a zero there is the press arriving -- from either console's wire byte.
local lastswb = nil
_G._pl_swb = sp:install_write_tap(DMSWB, DMSWB, "dmswb", function(off, data, mask)
    local down = (data & 0x01) == 0
    local was = lastswb
    lastswb = down
    if down and was ~= true then
        print(string.format("RESET-ON-WIRE t%d raw%d", ticks, sp:readv_u8(DMTICK)))
    end
end)

local nb = 0
-- THE TIMER ARM, NOT CXCLR. Dodge 'Em never strobes a collision register -- the
-- same fact that makes a stalled frame free -- so a tap there fires only when
-- the RAM clear sweeps the TIA. $F1A2 writes TIM64T exactly once per frame, in
-- the RIOT at $0296 where no clear can reach it.
_G._pl = sp:install_write_tap(0x0296, 0x0296, "tim64t", function(off, data, mask)
    if wlo and ticks >= wlo and ticks <= whi then
        -- adv is DMADV, the gate's own verdict for this frame: $FF ran the
        -- logic chain, $00 stalled. err's high nibble is the stall run-length.
        -- The wire, not just the consequence. loc/ring are the exact two
        -- bytes DMMIX combined for this tick -- the local ring slot the
        -- capture of d ticks ago went into, and the remote slot the peer's
        -- record for this tick went into -- and swb is what came out. Two
        -- consoles at the same CLOCK with different swb have been handed
        -- different inputs, and these say which side handed them over.
        local t = sp:readv_u8(DMTICK)
        local ring, loc, pad = {}, {}, {}
        -- BOTH RINGS IN FULL, one byte a slot: a whole console per tick.
        for i = 0, 7 do
            ring[#ring + 1] = string.format("%02X", sp:readv_u8(DMRING + i))
        end
        for i = 0, 3 do
            loc[#loc + 1] = string.format("%02X", sp:readv_u8(DMLOC + i))
        end
        for i = 0, 1 do
            pad[#pad + 1] = string.format("%02X", sp:readv_u8(0xE2 + i))
        end
        print(string.format(
            "F t%d raw%d ph%02X adv%02X err%02X fr%02X var%02X swa%02X swb%02X rwat%d pad%s | L%s R%s",
            ticks, t, sp:readv_u8(DMENT) & 0xC0,
            sp:readv_u8(SYM.DMADV), sp:readv_u8(DMERR), sp:readv_u8(CLOCK),
            sp:readv_u8(0x80), sp:readv_u8(DMSWA), sp:readv_u8(DMSWB),
            sp:readv_u8(DMRWAT), table.concat(pad, ""),
            table.concat(loc, " "), table.concat(ring, " ")))
    end
    if (sp:readv_u8(DMENT) & 0xC0) ~= 0x40 then return end
    nb = nb + 1
    if inject and not injected and nb >= inject then
        injected = true
        -- $B5 IS PLAYER A'S SAVED STATE, and the choice took three tries.
        --
        -- A car's position was the obvious pick and it is useless: $9B and $A2
        -- are driven from the stick and the track every tick, so a corruption
        -- there is gone by the next one without anything having repaired it.
        -- The harness would report "recovered after 1 tick" with the relay
        -- having seen nothing -- a test that passes itself (Video Olympics
        -- 3.18).
        --
        -- $98 looked like the answer, being called the score, and is not: its
        -- low seven bits are a DIGIT-POINTER WALK. LFB7C steps them down by six
        -- and resets at $0B, so the game churns them on its own schedule and a
        -- nudge is either absorbed or lost.
        --
        -- $B5-$BB is player A's saved block. Nothing writes it but LF5A0's
        -- swap at a round end, it is in DMCRC, and one is the smallest desync
        -- there is: exactly the size a real one starts at.
        was = sp:readv_u8(0xB5)
        injwatch = INJHOLD
        print(string.format("INJECT tick %d: $B5 was $%02X, holding +1 for %d "
                            .. "ticks", nb, was, INJHOLD))
    end
    if injwatch > 0 and nb ~= lastinj then
        lastinj = nb
        injwatch = injwatch - 1
        sp:write_u8(0xB5, (sp:readv_u8(0xB5) + 1) & 0xFF)
    end
    local b = {}
    -- EXACTLY WHAT DMCRC COVERS, and nothing else.
    --
    -- The first version dumped $80-$F8 whole, which reported "the last 120
    -- ticks do not agree" on a pair the relay had just verified across 2025
    -- CRC rounds with no mismatch at all. Both were right: the range included
    -- the four synthetic-controller shadows, which the netcode FILLS from the
    -- wire and which differ between host and guest by construction, and $9F,
    -- which carries each player's own black-and-white switch.
    --
    -- Comparing those is the same mistake the rig's SNAP/LOCAL split exists to
    -- avoid -- asserting that the two players have their hands in the same
    -- place -- and here it turned a working repair gate into one that could
    -- never pass.
    for _, r in ipairs({ {0x81,0x86}, {0x94,0x98}, {0x9B,0x9E},
                         {0xA2,0xA5}, {0xAB,0xAB}, {0xB5,0xBB} }) do
        for a = r[1], r[2] do
            b[#b + 1] = string.format("%02X", sp:readv_u8(a))
        end
    end
    -- ...and the dot bitmap, out of the cartridge plane it lives in now.
    for a = 0x1AE0, 0x1AE8 do
        b[#b + 1] = string.format("%02X", sp:readv_u8(a))
    end
    -- The ROM's own raw tick rides along so the two numbering schemes can be
    -- checked against each other rather than trusted.
    print(string.format("S %d %d %s", nb, sp:readv_u8(DMTICK),
                        table.concat(b, "")))
end)

_G._pl_stop = emu.add_machine_stop_notifier(function()
    print(string.format("PLAY ticks=%d err=$%02X state=%d ent=$%02X frames=%d",
        nb, sp:readv_u8(DMERR), sp:readv_u8(DMNST), sp:readv_u8(DMENT),
        frames))
end)
