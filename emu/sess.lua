-- sess.lua -- did the session get as far as a match?
--
-- It reads the netcode's own cells rather than the screen: DMENT says whether
-- a match is running and which role we were given, DMERR carries the reason
-- when one is not. Both are published by dmsess.inc before it hands the
-- console to the game, so a single sample after the handover tells the whole
-- story.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local SYM = dofile(os.getenv("DMSYMS") or "build/dmsyms.lua")
-- The cartridge publishes the active path buffer's length at $1F17, so
-- "did the devicespec get built" is a question with a direct answer rather
-- than an inference from what fujinet-pc logged.
local pathc, patho, nopen = 0, 0, 0
_G._se_pc = mem:install_write_tap(0x1DF3, 0x1DF3, "pathc", function() pathc = pathc + 1 end)
_G._se_po = mem:install_write_tap(0x1DF4, 0x1DF4, "patho", function() patho = patho + 1 end)

local frame, done = 0, false
local seen = {}
_G._se = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    local e = mem:read_u8(SYM.DMENT)
    seen[e & 0x3F] = true            -- mask the tick phase out of it
    if done or frame < tonumber(os.getenv("FRAME_COUNT") or "900") then return end
    done = true
    local ks = {}
    for k in pairs(seen) do ks[#ks+1] = string.format("%02X", k) end
    table.sort(ks)
    print(string.format("SESS pathchars=%d pathops=%d pathlen=%d",
                        pathc, patho,
                        mem:read_u8(0x1F17) | (mem:read_u8(0x1F18) << 8)))
    print(string.format("SESS frames=%d ent=%s err=%02X tick=%02X nst=%02X",
                        frame, table.concat(ks, ","),
                        mem:read_u8(SYM.DMERR), mem:read_u8(SYM.DMTICK),
                        mem:read_u8(SYM.DMNST)))
end)
