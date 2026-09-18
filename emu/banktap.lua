-- banktap.lua -- is the console actually switching banks?
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local sw, arm, first = {}, {}, {}
local n, frames = 0, 0

_G._bt_rd = mem:install_read_tap(0x1D00, 0x1DFF, "ctrl", function(off, data)
    local lo = off & 0xFF
    if lo >= 0x80 and lo <= 0xEF then
        n = n + 1
        sw[lo - 0x80] = (sw[lo - 0x80] or 0) + 1
        if not first[lo - 0x80] then first[lo - 0x80] = frames end
    elseif lo == 0xFC or lo == 0xFD then
        arm[lo] = (arm[lo] or 0) + 1
    end
end)
_G._bt_wr = mem:install_write_tap(0x1D00, 0x1DFF, "ctrlw", function(off, data)
    local lo = off & 0xFF
    if lo >= 0x80 and lo <= 0xEF then
        n = n + 1
        sw[lo - 0x80] = (sw[lo - 0x80] or 0) + 1
        if not first[lo - 0x80] then first[lo - 0x80] = frames end
    elseif lo == 0xFC or lo == 0xFD then
        arm[lo] = (arm[lo] or 0) + 1
    end
end)

_G._bt = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames == 300 then
        print(string.format("BANKTAP frames=%d accesses=%d", frames, n))
        print(string.format("  arm $1DFC=%d $1DFD=%d",
                            arm[0xFC] or 0, arm[0xFD] or 0))
        for b = 0, 6 do
            if sw[b] then
                print(string.format("  bank %d selected %d times (first at frame %d)",
                                    b, sw[b], first[b]))
            end
        end
        print(string.format("  cart says live bank = %d, flags = $%02X",
                            mem:read_u8(0x1F0E), mem:read_u8(0x1F0F)))
        print(string.format("  magic = %c%c", mem:read_u8(0x1F09), mem:read_u8(0x1F0A)))
    end
end)
