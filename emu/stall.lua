-- stall.lua -- does a stalled frame actually stall the simulation?
--
-- The stall is the primitive the whole transport rests on: a console waits for
-- a peer by drawing a frame with the game-logic chain skipped. Two things have
-- to be true and they pull in opposite directions --
--
--   * the SIMULATION must stop. The cars must not move, the score must not
--     change, the counters must not step.
--   * the PICTURE must not. The frame must still be 262 lines, because a
--     console that stutters visibly every time its peer is a tick behind is
--     not absorbing the latency, it is showing it.
--
-- Built with DMSTALLT=1 the ROM stalls every other tick with no network
-- involved, so this measures the mechanism rather than the transport.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local CELLS = { 0x9B, 0xA2, 0xA3, 0x82 }   -- cars, chase car, frame counter

local FRAME = 1 / 59.92
local LINE  = FRAME / 262
local last, lines, n = nil, {}, 0
_G._st_v = mem:install_write_tap(0x00, 0x00, "vsync", function(off, data)
    if (data & 0x02) == 0 then return end
    local t = manager.machine.time:as_double()
    if last then
        local l = math.floor((t - last) / LINE + 0.5)
        lines[l] = (lines[l] or 0) + 1
        n = n + 1
    end
    last = t
end)

-- Drive a real match: an attract screen's cars move on their own schedule.
local F = {}
for k, t in pairs({ select = { ":SWB", "Select Game" }, reset = { ":SWB", "Reset Game" },
                    p1u = { ":joyport1:joy:JOY", "P1 Up" },
                    p1d = { ":joyport1:joy:JOY", "P1 Down" } }) do
    local p = manager.machine.ioport.ports[t[1]]
    F[k] = p and p.fields[t[2]] or false
end
local function press(k, on) if F[k] then F[k]:set_value(on and 1 or 0) end end

local frame, done, changed, samples = 0, false, 0, 0
local prev = nil
_G._st_f = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    press("select", (frame > 60 and frame < 70) or (frame > 110 and frame < 120))
    press("reset", frame > 170 and frame < 180)
    if frame > 200 then
        local ph = math.floor(frame / 17) % 2
        press("p1u", ph == 0); press("p1d", ph == 1)
    end

    if frame > 400 then
        local cur = {}
        for i, a in ipairs(CELLS) do cur[i] = mem:read_u8(a) end
        if prev then
            samples = samples + 1
            for i = 1, #CELLS do
                if cur[i] ~= prev[i] then changed = changed + 1; break end
            end
        end
        prev = cur
    end

    if done or frame < tonumber(os.getenv("FRAME_COUNT") or "1800") then return end
    done = true
    local keys = {}
    for k in pairs(lines) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return lines[a] > lines[b] end)
    print(string.format("STALL frames=%d moved=%d of %d (%.1f%%) lines_mode=%d",
                        frame, changed, samples,
                        samples > 0 and 100 * changed / samples or 0, keys[1]))
    local out = {}
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = string.format("%d:%d", k, lines[k]) end
    print("STALL lines " .. table.concat(out, " "))
end)
