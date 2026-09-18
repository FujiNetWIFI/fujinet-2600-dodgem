-- ramdump.lua -- the logical sim state, cell by cell, at chosen frames.
-- det.lua says THAT two builds differ; this says WHERE.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local SPLIT = os.getenv("DET_SPLIT") == "1"
local AT = {}
for f in (os.getenv("DUMP_AT") or "60,120,300"):gmatch("[^,]+") do
    AT[tonumber(f)] = true
end
local DOTS, SAVB = 0x1AE0, 0x1AF0
local function cell(a)
    if SPLIT then
        if a >= 0xAC and a <= 0xB4 then return mem:read_u8(DOTS + (a - 0xAC)) end
        if a >= 0xBC and a <= 0xC2 then return mem:read_u8(SAVB + (a - 0xBC)) end
    end
    return mem:read_u8(a)
end
-- The same landmark det.lua uses: CXCLR, strobed once a frame at $F249. A
-- dump taken at a different point from the comparison is a dump of a different
-- question.
local frame, settled = 0, false
_G._rd_wait = emu.add_machine_frame_notifier(function() settled = true end)
_G._rd = mem:install_write_tap(0x2C, 0x2C, "cxclr", function(off, data)
    if not settled then return end
    frame = frame + 1
    if not AT[frame] then return end
    local t = {}
    for a = 0x80, 0xF8 do t[#t + 1] = string.format("%02X", cell(a)) end
    print(string.format("RAM %d %s", frame, table.concat(t, "")))
end)
