-- adv.lua -- does each console ADVANCE the same number of frames?
--
-- That is the invariant the whole lockstep rests on and nothing was asserting
-- it. The sim advances once per FRAME; the inputs are fixed once per TICK, and
-- a tick is DMK frames. A stall skips one frame's logic. So if a peer's record
-- lands PART WAY THROUGH a tick, the frames before it stalled and the frames
-- after it advanced -- and this console has taken fewer logic steps for that
-- tick than its peer did. Nothing brings them back.
--
-- It also samples DMSWB properly. $87 is band-local: the kernel uses it as
-- glyph scratch, so reading it from a frame notifier catches whatever the
-- kernel happens to be holding -- which is how the first version of this
-- reported values ($A0, $E0) that the shim cannot produce. Sample it WHERE IT
-- IS WRITTEN, bucketed by the PC that wrote it, and the shim's store names
-- itself.
local SYM = dofile(os.getenv("DMSYMS") or "build/dmsyms.lua")
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]

local adv, stall, frames = 0, 0, 0
local bypc = {}

_G._av_swb = sp:install_write_tap(SYM.DMSWB, SYM.DMSWB, "swb", function(off, data)
    local pc = cpu.state["PC"].value
    bypc[pc] = bypc[pc] or {}
    bypc[pc][data] = (bypc[pc][data] or 0) + 1
end)

-- Counted on the OVERSCAN arm, which is the last thing before the band that
-- reads DMADV -- so the value counted is the one the chain will act on.
_G._av = sp:install_write_tap(0x0296, 0x0296, "tim64t", function(off, data)
    if data ~= 0x23 then return end                 -- the overscan arm only
    if (sp:read_u8(SYM.DMENT) & 0x01) == 0 then return end
    frames = frames + 1
    if sp:read_u8(SYM.DMADV) ~= 0 then adv = adv + 1 else stall = stall + 1 end
end)

local done = false
_G._av_t = emu.add_machine_frame_notifier(function()
    if done or frames < tonumber(os.getenv("ADV_COUNT") or "1200") then return end
    done = true
    print(string.format("ADV frames=%d advanced=%d stalled=%d tick=%d $82=$%02X",
        frames, adv, stall, sp:read_u8(SYM.DMTICK), sp:read_u8(0x82)))
    local pcs = {}
    for pc in pairs(bypc) do pcs[#pcs + 1] = pc end
    table.sort(pcs)
    for _, pc in ipairs(pcs) do
        local ks, tot = {}, 0
        for v, c in pairs(bypc[pc]) do ks[#ks + 1] = v; tot = tot + c end
        table.sort(ks)
        local o = {}
        for _, v in ipairs(ks) do o[#o + 1] = string.format("$%02X:%d", v, bypc[pc][v]) end
        print(string.format("SWB wr @$%04X (%d)  %s", pc, tot, table.concat(o, " ")))
    end
    print("ADV DONE")
end)
