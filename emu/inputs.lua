-- inputs.lua -- M3: the game no longer reads a console port.
--
-- Every read of SWCHA, SWCHB, INPT4 or INPT5 must come from inside DMMIX, plus
-- ONE deliberate exception: $F0F5's SWCHB read, which picks black-and-white.
-- B/W is a local preference here -- each player keeps their own, it is not on
-- the wire -- so reading it live is correct rather than tolerated.
--
-- IT HAS TO DRIVE THE GAME, and this is the whole reason the harness is more
-- than four taps.
--
-- Sixteen of Dodge 'Em's twenty-four read sites are the four turn-decision
-- points, and every one of them sits behind `BIT $94 / BVC` -- they execute
-- only in the variation where a human drives the chase car. In ATTRACT the
-- branch is never taken. The first version of this gate sat in attract, saw
-- nine sites, and passed; then a SWCHA patch was deliberately removed and it
-- passed again, because the site it had just un-patched was never reached.
-- Even STOCK reads only two of its twenty-four sites in attract.
--
-- So: SELECT twice to reach the two-player variation, RESET to start, then
-- both sticks moving. And the state is ASSERTED, because a gate that drives
-- input the game ignores is the same gate that passed before.
local sp  = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local mem = sp

local seen, total = {}, 0
local function note(what)
    local k = string.format("%s@%04X", what, cpu.state["PC"].value)
    seen[k] = (seen[k] or 0) + 1
    total = total + 1
end
_G._in_a = sp:install_read_tap(0x0280, 0x0281, "swcha", function() note("SWCHA") end)
_G._in_b = sp:install_read_tap(0x0282, 0x0283, "swchb", function() note("SWCHB") end)
_G._in_4 = sp:install_read_tap(0x003C, 0x003C, "inpt4", function() note("INPT4") end)
_G._in_5 = sp:install_read_tap(0x003D, 0x003D, "inpt5", function() note("INPT5") end)

-- CACHED ONCE. A field looked up at the moment of pressing it is a fresh
-- wrapper and set_value on it is lost.
local FIELDS = {}
local TAGS = {
    select = { ":SWB", "Select Game" },   reset = { ":SWB", "Reset Game" },
    p1u = { ":joyport1:joy:JOY", "P1 Up" },   p1d = { ":joyport1:joy:JOY", "P1 Down" },
    p1l = { ":joyport1:joy:JOY", "P1 Left" }, p1r = { ":joyport1:joy:JOY", "P1 Right" },
    p2u = { ":joyport2:joy:JOY", "P2 Up" },   p2d = { ":joyport2:joy:JOY", "P2 Down" },
    p2l = { ":joyport2:joy:JOY", "P2 Left" }, p2r = { ":joyport2:joy:JOY", "P2 Right" },
    p1b = { ":joyport1:joy:JOY", "P1 Button 1" },
    p2b = { ":joyport2:joy:JOY", "P2 Button 1" },
}
for k, t in pairs(TAGS) do
    local p = manager.machine.ioport.ports[t[1]]
    FIELDS[k] = p and p.fields[t[2]] or false
end
local function press(k, on) local f = FIELDS[k]; if f then f:set_value(on and 1 or 0) end end

local frame, done = 0, false
local modeseen, runseen = {}, {}
local LIMIT = tonumber(os.getenv("FRAME_COUNT") or "1800")

_G._in_r = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    modeseen[mem:read_u8(0x94)] = true
    runseen[mem:read_u8(0x95)] = true

    -- SELECT twice: $94's mode bits walk 00 -> 80 -> C0, and $C0 is the
    -- variation where both players are active.
    press("select", (frame > 60 and frame < 70) or (frame > 110 and frame < 120))
    press("reset",  frame > 170 and frame < 180)
    if frame > 200 then
        local ph = math.floor(frame / 17) % 4
        press("p1u", ph == 0); press("p1d", ph == 1)
        press("p1l", ph == 2); press("p1r", ph == 3)
        press("p2d", ph == 0); press("p2u", ph == 1)
        press("p2r", ph == 2); press("p2l", ph == 3)
        press("p1b", ph == 0); press("p2b", ph == 2)
    end

    if done or frame < LIMIT then return end
    done = true
    local keys = {}
    for k in pairs(seen) do keys[#keys + 1] = k end
    table.sort(keys)
    print(string.format("INPUTS frames=%d reads=%d sites=%d", frame, total, #keys))
    for _, k in ipairs(keys) do
        print(string.format("INPUTS   %s  x%d", k, seen[k]))
    end
    local ms, rs = {}, {}
    for v in pairs(modeseen) do ms[#ms + 1] = string.format("%02X", v) end
    for v in pairs(runseen) do rs[#rs + 1] = string.format("%02X", v) end
    table.sort(ms); table.sort(rs)
    print("INPUTSTATE mode=" .. table.concat(ms, ",") .. " run=" .. table.concat(rs, ","))
end)
