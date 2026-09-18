-- ftrace.lua -- what a 358-line frame actually DOES, in order, with timing.
--
-- Everything inferred from the INTIM values alone was wrong: the arms are the
-- stock $28 and $23 and INTIM was still read as 113. So this stops inferring
-- and records the frame as a sequence -- bank switches, timer arms, WSYNCs,
-- VSYNC, and the transport's own dispatch -- each stamped in scanlines from
-- the previous VSYNC.
local FRAME = 1 / 59.92
local LINE  = FRAME / 262
local DMJT = tonumber(os.getenv("DMJT") or "0x12C3")

local sp = manager.machine.devices[":maincpu"].spaces["program"]
local ev, last, n, out = {}, nil, 0, {}
local nlong, nshort = 0, 0

local function at()
    local t = manager.machine.time:as_double()
    return last and ((t - last) / LINE) or 0
end
local function log(s)
    if #ev < 200 then ev[#ev + 1] = string.format("%.0f:%s", at(), s) end
end

_G._ft_bank = sp:install_write_tap(0x1D80, 0x1D8F, "bank", function(off) log("B" .. (off - 0x1D80)) end)
_G._ft_arm  = sp:install_write_tap(0x0294, 0x0297, "arm", function(off, data) log(string.format("T%02X", data)) end)
_G._ft_jt   = sp:install_read_tap(DMJT, DMJT, "jt", function() log("s") end)
_G._ft_tim  = sp:install_read_tap(0x0284, 0x0284, "intim", function(off, data) log("i" .. data) end)

-- BRACKET THE TICK-BOUNDARY WORK. DMCAP opens with `inc DMTICK` and DMCRC
-- closes with `sta DMCRCV`, so a write to each is the entry and the exit.
_G._ft_cap = sp:install_write_tap(0xAD, 0xAD, "tick", function() log("CAP{") end)
_G._ft_crc = sp:install_write_tap(0xB1, 0xB1, "crcv", function() log("}CRC") end)
-- ...and the blit port, in case a poke is firing where nothing should.
_G._ft_blt = sp:install_write_tap(0x1DF0, 0x1DFF, "blit", function(off) log(string.format("P%02X", off & 0xFF)) end)

_G._ft_vs = sp:install_write_tap(0x00, 0x00, "vsync", function(off, data, mask)
    if (data & 0x02) == 0 then return end
    local t = manager.machine.time:as_double()
    if last then
        local lines = math.floor((t - last) / LINE + 0.5)
        n = n + 1
        if ((lines > 300 and nlong < 1) or (lines < 300 and nshort < 1)) then
            if lines > 300 then nlong = nlong + 1 else nshort = nshort + 1 end
            -- COLLAPSE THE SPIN. `LDA INTIM / BNE` reads every few cycles and
            -- would bury the structure in thousands of identical entries.
            local c, prev = {}, nil
            for _, e in ipairs(ev) do
                local kind = e:match(":(%a)")
                if kind == "i" and prev == "i" then
                    c[#c] = c[#c]:gsub("x%d+$", "") .. "x" .. ((tonumber(c[#c]:match("x(%d+)$") or "1")) + 1)
                else
                    c[#c + 1] = e
                end
                prev = kind
            end
            out[#out + 1] = string.format("== %d-line frame ==\n%s", lines, table.concat(c, " "))
        end
    end
    last = t; ev = {}
end)

local REPORT_AT = tonumber(os.getenv("FRAME_COUNT") or "400")
local done = false
_G._ft_tick = emu.add_machine_frame_notifier(function()
    if done or n < REPORT_AT then return end
    done = true
    for _, s in ipairs(out) do print(s) end
    print("FTRACE DONE")
end)
