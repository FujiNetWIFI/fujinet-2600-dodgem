-- pokes.lua -- how many blits a frame fires, against how long that frame is.
local FRAME = 1 / 59.92
local LINE  = FRAME / 262
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local fires, caps, last, n, hist = 0, 0, nil, 0, {}
_G._pk_go  = sp:install_write_tap(0x1DFA, 0x1DFA, "fire", function() fires = fires + 1 end)
_G._pk_cap = sp:install_write_tap(0xAD, 0xAD, "tick", function() caps = caps + 1 end)
_G._pk_vs = sp:install_write_tap(0x00, 0x00, "vsync", function(off, data)
    if (data & 0x02) == 0 then return end
    local t = manager.machine.time:as_double()
    if last then
        local lines = math.floor((t - last) / LINE + 0.5)
        local k = string.format("%d lines, %d blits, %s", lines, fires,
                                caps > 0 and "TICK" or "----")
        hist[k] = (hist[k] or 0) + 1; n = n + 1
    end
    last = t; fires = 0; caps = 0
end)
local done = false
_G._pk_t = emu.add_machine_frame_notifier(function()
    if done or n < tonumber(os.getenv("FRAME_COUNT") or "400") then return end
    done = true
    local ks = {}
    for k in pairs(hist) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return hist[a] > hist[b] end)
    for i = 1, math.min(#ks, 12) do print(string.format("%5d x  %s", hist[ks[i]], ks[i])) end
    print("POKES DONE")
end)
