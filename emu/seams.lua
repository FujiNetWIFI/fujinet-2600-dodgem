-- seams.lua -- where in the frame does each bank switch land?
--
-- A switch costs ~20 cycles. That is FREE if it lands in front of a WSYNC or
-- inside a timed band, because the wait at the far end swallows it, and it is
-- ADDED TO THE FRAME if it lands anywhere else. `make frames` says the frame
-- grew; this says which switch grew it.
--
-- The scanline comes from the clock, not from screen:vpos() -- that method
-- does not exist in this MAME's Lua and calling it inside a tap fails
-- silently, leaving a harness that taps 2549 times and reports nothing.
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local FRAME = 1 / 59.92
local LINE  = FRAME / 262

local lastvs, at, frame, done = nil, {}, 0, false

_G._sm_v = sp:install_write_tap(0x00, 0x00, "vsync", function(off, data)
    if (data & 0x02) ~= 0 then lastvs = manager.machine.time:as_double() end
end)

_G._sm_b = sp:install_write_tap(0x1D80, 0x1D8F, "bank", function(off)
    if not lastvs then return end
    local line = (manager.machine.time:as_double() - lastvs) / LINE
    local b = off - 0x1D80
    at[b] = at[b] or { n = 0, sum = 0, min = 9e9, max = -1 }
    local e = at[b]
    e.n = e.n + 1; e.sum = e.sum + line
    if line < e.min then e.min = line end
    if line > e.max then e.max = line end
end)

_G._sm_r = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if done or frame < 600 then return end
    done = true
    print("SEAMS bank  switches   scanline within the frame: mean  min  max")
    for b = 0, 6 do
        local e = at[b]
        if e then
            print(string.format("SEAMS   %d   %8d                     %6.1f %5.1f %5.1f",
                                b, e.n, e.sum / e.n, e.min, e.max))
        end
    end
end)
