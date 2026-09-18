-- ptrtap.lua -- who writes $A7/$A8, and with what?
-- The PC inside a memory tap is not the writing instruction's (Dragster 3.7),
-- so this reports the VALUE and the frame, which are unambiguous, and uses the
-- PC only as a hint.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local frame, settled, n = 0, false, 0
_G._pt_f = emu.add_machine_frame_notifier(function() settled = true end)
_G._pt_c = mem:install_write_tap(0x2C, 0x2C, "cxclr", function()
    if settled then frame = frame + 1 end
end)
_G._pt = mem:install_write_tap(0xA7, 0xA8, "ptr", function(off, data)
    if not settled or frame < 125 or frame > 140 then return end
    n = n + 1
    if n < 60 then
        print(string.format("PTR f%-4d $%02X <- %02X  (pc~%04X)",
                            frame, off, data, cpu.state["PC"].value))
    end
end)
