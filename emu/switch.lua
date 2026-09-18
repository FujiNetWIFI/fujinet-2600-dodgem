-- switch.lua -- is the SYNTHETIC SWCHB a faithful port-space byte?
--
-- `make inputs` proves every console-port read comes from the shim. It says
-- nothing about whether what the shim HANDS BACK means what the game thinks it
-- means, and that is a separate claim with its own failure: the wire byte
-- carries SELECT at bit 5 and RESET at bit 4, SWCHB carries them at bits 1 and
-- 0, and DMNETSW stored them straight across without the translation. Both
-- bits read zero for ever -- and they are ACTIVE LOW, so the game saw RESET and
-- SELECT held down from the moment a match began.
--
-- Both consoles computed the same wrong byte, so every gate that measures
-- agreement passed. Combat's PORTING.md 4.18 three times over: a gate that
-- only measures agreement proves nothing.
--
-- So this one asserts VALUES, against the hardware's own definition:
--
--   SWCHB bit 0  RESET,  active low
--   SWCHB bit 1  SELECT, active low
--   SWCHB bit 3  B/W -- LOCAL, and it must not follow the peer
--
-- Idle: both must read 1. Pressed: the matching bit must reach 0.
local SYM = dofile(os.getenv("DMSYMS") or "build/dmsyms.lua")
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

local FLD = {}
for k, t in pairs({ select = { ":SWB", "Select Game" },
                    reset  = { ":SWB", "Reset Game" } }) do
    local p = manager.machine.ioport.ports[t[1]]
    FLD[k] = p and p.fields[t[2]] or false
end
if not (FLD.select and FLD.reset) then
    print("SWITCH FAIL -- no console-switch fields to drive")
end
local function press(k, on) if FLD[k] then FLD[k]:set_value(on and 1 or 0) end end

-- THE SCHEDULE IS RELATIVE TO THE MATCH, not to power-on: the boot bank blocks
-- while it pairs, and a schedule counted from reset spends itself in there
-- (PORTING.md 13). Nothing is sampled until DME_NET is actually set.
-- AND EVERY WINDOW HAS A SETTLING MARGIN, BECAUSE THE WHOLE POINT IS A DELAY.
--
-- A press reaches the simulation DMD ticks after it is made -- 2 ticks of 4
-- frames, so 8 -- and it leaves the same way. Without a margin the tail of each
-- press bleeds into the idle window after it, and this gate failed a correct
-- build on 13 frames in 180: exactly the lag it exists downstream of. The
-- margin is generous rather than exact, because asserting the delay's precise
-- length is `make stall`'s job and not this one.
local SETTLE, HOLD, LAG = 90, 60, 24
local ORDER = { "idle", "sel", "idle", "rst", "idle" }
local matched, f = nil, 0
local seen = { idle = {}, sel = {}, rst = {} }
local function phase_of(d)          -- the phase to DRIVE
    if d < SETTLE then return nil end
    local i = (d - SETTLE) // HOLD
    return ORDER[i + 1]
end
local function sample_of(d)         -- ...and the phase to BELIEVE
    if d < SETTLE then return nil end
    if (d - SETTLE) % HOLD < LAG then return nil end
    return phase_of(d)
end

-- WHERE THE SHADOW IS SAMPLED IS THE WHOLE GATE.
--
-- $87 is BAND-LOCAL: the kernel uses it as glyph merge scratch, and it is
-- written about fourteen times a frame -- twelve of those by the kernel. A read
-- from a frame notifier lands wherever the emulator's schedule happens to put
-- it, so the first version of this gate reported values ($A0, $E0) the shim
-- cannot produce and failed a build that was correct.
--
-- Of the four PCs that write $87, the last one before VSYNC is the overscan
-- derivation. So sample ON THE VSYNC WRITE: that is the value the shim last
-- produced, which is the value the claim is about.
local phase = nil
local done = false

_G._sw_vs = mem:install_write_tap(0x00, 0x00, "vsync", function(off, data)
    if done or (data & 0x02) == 0 or phase == nil then return end
    local b = mem:read_u8(SYM.DMSWB)
    seen[phase][b] = (seen[phase][b] or 0) + 1
end)

_G._sw = emu.add_machine_frame_notifier(function()
    if done then return end
    f = f + 1
    local ent = mem:read_u8(SYM.DMENT)
    if (ent & 0x01) == 0 then return end        -- not in a match yet
    matched = matched or f
    local d = f - matched
    local ph = phase_of(d)
    press("select", ph == "sel")
    press("reset",  ph == "rst")
    phase = sample_of(d)
    if d < SETTLE + HOLD * 5 then return end

    done = true
    local function bits(t, mask)          -- how often the masked bit was LOW
        local low, tot = 0, 0
        for v, c in pairs(t) do tot = tot + c; if (v & mask) == 0 then low = low + c end end
        return low, tot
    end
    local function show(name, t)
        local ks = {}
        for v in pairs(t) do ks[#ks + 1] = v end
        table.sort(ks)
        local o = {}
        for _, v in ipairs(ks) do o[#o + 1] = string.format("$%02X:%d", v, t[v]) end
        print(string.format("SWCHB %-5s %s", name, table.concat(o, " ")))
    end
    show("idle", seen.idle); show("sel", seen.sel); show("rst", seen.rst)

    local ok = true
    local ilow1, itot = bits(seen.idle, 0x01)
    local ilow2       = bits(seen.idle, 0x02)
    if itot == 0 then print("  FAIL never sampled an idle window"); ok = false end
    if ilow1 > 0 then
        print(string.format("  FAIL RESET (bit 0) reads PRESSED in %d of %d idle frames", ilow1, itot)); ok = false
    end
    if ilow2 > 0 then
        print(string.format("  FAIL SELECT (bit 1) reads PRESSED in %d of %d idle frames", ilow2, itot)); ok = false
    end
    -- A BIT THAT IS ALREADY LOW CANNOT BE EVIDENCE OF A PRESS. The first run of
    -- this gate printed "ok SELECT reached the game in 60 of 60 held frames"
    -- about a build in which bit 1 was stuck at zero -- the press proved
    -- nothing, because the bit it would have cleared was already clear. So the
    -- press check is only meaningful where the idle baseline was clean.
    local function press_claim(name, t, mask, idle_clean)
        local low, tot = bits(t, mask)
        if not idle_clean then
            print(string.format("  --   %s: no claim -- the bit is low at idle too", name))
            return false
        end
        if tot == 0 or low == 0 then
            print(string.format("  FAIL %s was held and never reached the game", name))
            return false
        end
        print(string.format("  ok   %s reached the game in %d of %d held frames", name, low, tot))
        return true
    end
    if not press_claim("SELECT", seen.sel, 0x02, ilow2 == 0 and itot > 0) then ok = false end
    if not press_claim("RESET",  seen.rst, 0x01, ilow1 == 0 and itot > 0) then ok = false end
    print(ok and "SWITCH PASS" or "SWITCH FAIL")
end)
