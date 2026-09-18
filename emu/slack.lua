-- slack.lua -- how many cycles are left at each timed band's spin?
--
-- The network machine is stepped in front of a spin, under an INTIM gate, so
-- it cannot overrun by construction -- but only if there is slack to step in.
-- This measures how much, on a real game, for BOTH bands.
--
-- DODGE 'EM ARMS TIM64T TWICE A FRAME, which the sibling harness did not have
-- to cope with: it re-arms its sampler on any write to $0296 and takes the
-- first INTIM read after it. Here the two arms are told apart for free and
-- without reading the PC -- which inside a tap is not the instruction's
-- anyway (Dragster 3.7) -- because they write DIFFERENT VALUES: $28 for the
-- vblank band and $23 for overscan. The write tap latches the value and the
-- read tap attributes the sample to the band that value names.
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local mem = sp

local NAME = { [0x28] = "vblank", [0x23] = "overscan", [0x24] = "overscan(stock)" }
local armed, stat = nil, {}
local firstread = false

_G._sl_w = sp:install_write_tap(0x0296, 0x0296, "tim64t", function(off, data)
    armed = data
    firstread = true
end)

-- INTIM is $0284. The spin reads it repeatedly; the FIRST read after an arm is
-- the one that says how much of the band the game did not use.
_G._sl_r = sp:install_read_tap(0x0284, 0x0284, "intim", function(off, data)
    if not armed or not firstread then return end
    firstread = false
    local k = NAME[armed] or string.format("$%02X", armed)
    local e = stat[k]
    if not e then e = { n = 0, sum = 0, min = 999, max = -1, zero = 0 }; stat[k] = e end
    e.n = e.n + 1; e.sum = e.sum + data
    if data < e.min then e.min = data end
    if data > e.max then e.max = data end
    if data == 0 then e.zero = e.zero + 1 end
end)

-- Drive the game into a real match, for the same reason make inputs must:
-- an idle attract screen is not the workload the netcode has to fit beside.
local F = {}
for k, t in pairs({ select = { ":SWB", "Select Game" }, reset = { ":SWB", "Reset Game" },
                    p1u = { ":joyport1:joy:JOY", "P1 Up" },
                    p1d = { ":joyport1:joy:JOY", "P1 Down" },
                    p2u = { ":joyport2:joy:JOY", "P2 Up" },
                    p2d = { ":joyport2:joy:JOY", "P2 Down" } }) do
    local p = manager.machine.ioport.ports[t[1]]
    F[k] = p and p.fields[t[2]] or false
end
local function press(k, on) if F[k] then F[k]:set_value(on and 1 or 0) end end

local frame, done = 0, false
_G._sl_f = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    press("select", (frame > 60 and frame < 70) or (frame > 110 and frame < 120))
    press("reset", frame > 170 and frame < 180)
    if frame > 200 then
        local ph = math.floor(frame / 17) % 2
        press("p1u", ph == 0); press("p1d", ph == 1)
        press("p2d", ph == 0); press("p2u", ph == 1)
    end
    if done or frame < tonumber(os.getenv("FRAME_COUNT") or "1800") then return end
    done = true
    print("SLACK band        samples   INTIM at the spin: mean   min   max   exhausted")
    for k, e in pairs(stat) do
        print(string.format("SLACK %-12s %7d                      %5.1f %5d %5d   %d",
                            k, e.n, e.sum / e.n, e.min, e.max, e.zero))
    end
    print("SLACK (INTIM counts 64-cycle ticks; 1 tick = 64 cycles = 0.84 scanlines)")
end)
