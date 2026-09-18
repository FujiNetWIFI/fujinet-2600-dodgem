-- smoke.lua -- does the split image run at all, and is its state moving?
--
-- The cheapest possible question, asked before any gate that compares two
-- builds against each other: a pair of machines can agree about nothing and a
-- gate that only measures agreement will pass them (Combat 4.18). So this
-- measures absolutes -- frames, and whether the game's own cells take more
-- than one value.
--
-- THE NOTIFIER TOKEN IS IN A GLOBAL. MAME garbage-collects them, and a
-- collected notifier simply stops firing: the run completes, prints nothing,
-- and looks like a ROM that did nothing rather than a harness that stopped
-- watching. Dragster's PORTING.md 3.9 is the account.
local mac = manager.machine
local mem = mac.devices[":maincpu"].spaces["program"]

local frames = 0
local seen = {}
local RAM = { 0x94, 0x95, 0x96, 0x98, 0x9B, 0xA2, 0xA3 }
local NAME = { [0x94] = "mode", [0x95] = "run", [0x96] = "level",
               [0x98] = "score/active", [0x9B] = "car0", [0xA2] = "car1",
               [0xA3] = "chase" }
local LIMIT = tonumber(os.getenv("SMOKE_FRAMES") or "600")
local done = false

_G._smoke = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    for _, a in ipairs(RAM) do
        local v = mem:read_u8(a)
        seen[a] = seen[a] or {}
        seen[a][v] = true
    end
    if frames >= LIMIT and not done then
        done = true
        print(string.format("SMOKE frames=%d", frames))
        local moving, stuck = {}, {}
        for _, a in ipairs(RAM) do
            local n = 0
            for _ in pairs(seen[a] or {}) do n = n + 1 end
            local s = string.format("$%02X(%s):%d", a, NAME[a] or "?", n)
            table.insert(n > 1 and moving or stuck, s)
        end
        print("  moving: " .. table.concat(moving, " "))
        print("  stuck : " .. table.concat(stuck, " "))
    end
end)
