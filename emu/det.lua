-- det.lua -- does the split build play exactly like the 1980 cartridge?
--
-- Per frame, a checksum of the AUTHORITATIVE SIM STATE, printed so the two
-- runs can be diffed outside the emulator. It is not a screenshot comparison:
-- the picture is regenerated from state every frame, so comparing state is
-- both stricter and easier to localise when it differs.
--
-- WHAT IS COMPARED IS THE LOGICAL STATE, NOT THE ADDRESS.
--
-- Sixteen bytes of Dodge 'Em's own state -- the per-row dot bitmap that was
-- $AC-$B4 and player B's saved block that was $BC-$C2 -- do not live in RAM in
-- the split build. They live in a cartridge text plane, because this game uses
-- all 128 bytes of the RIOT and the netcode needed somewhere to be. So this
-- reads them from wherever the build under test keeps them and checksums them
-- in the same logical position.
--
-- That makes the gate prove the eviction as well as the split: if a poke
-- through the blit port lost a byte, or landed at the wrong plane offset, the
-- checksum diverges on the frame it happened.
--
-- A gate that only measures agreement proves nothing (Combat 4.18), so this
-- also reports how many DISTINCT states it saw. Two builds that both sit still
-- agree perfectly.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local SPLIT  = os.getenv("DET_SPLIT") == "1"
local FRAMES = tonumber(os.getenv("DET_FRAMES") or "1200")
local DOTS, SAVB = 0x1AE0, 0x1AF0        -- must match dmdefs.inc
local PIN, PINLO = 0x1756, 0xFE2E        -- must match tools/dmbanks.py

-- Cells the netcode BORROWED, which cannot match stock and must not be
-- compared. Combat 4.21's converse, in Video Olympics' words: a cell the
-- netcode fills is not state the netcode should check. These four are the
-- synthetic controller, living in kernel scratch the game does not use across
-- a band, because there were no free cells to have.
local BORROWED = { [0x80] = true, [0x87] = true, [0xA9] = true, [0xAA] = true }

-- The nine 16-bit pointers, by their LOW byte. Their VALUE differs between
-- builds by construction -- the tables they point into moved out of the
-- mailbox pages and into a bank -- but the place they point AT is the same.
-- The pinned span is one affine map, so a split pointer converts back to the
-- stock address it means and the comparison stays exact instead of being
-- weakened to an exclusion.
local PTRLO = { [0x88]=true,[0x8A]=true,[0x8C]=true,[0x8E]=true,[0x90]=true,
                [0x92]=true,[0xA0]=true,[0xA7]=true,[0xBA]=true }

-- The game's own cells. $AC-$B4 and $BC-$C2 are named by their STOCK
-- addresses and redirected below; everything else is read where it is.
local function cell(a)
    if BORROWED[a] then return 0 end
    if SPLIT then
        if a >= 0xAC and a <= 0xB4 then return mem:read_u8(DOTS + (a - 0xAC)) end
        if a >= 0xBC and a <= 0xC2 then return mem:read_u8(SAVB + (a - 0xBC)) end
        if PTRLO[a] then                      -- normalise the whole pointer
            local v = mem:read_u8(a) | (mem:read_u8(a + 1) << 8)
            return (v - PIN + PINLO) & 0xFF
        end
        if PTRLO[a - 1] then
            local v = mem:read_u8(a - 1) | (mem:read_u8(a) << 8)
            return ((v - PIN + PINLO) >> 8) & 0xFF
        end
    end
    return mem:read_u8(a)
end

-- SAMPLE ON THE GAME'S OWN LANDMARK, NOT MAME'S FRAME.
--
-- The first version sampled from a frame notifier, which fires at a fixed
-- point in emulated TIME. The two builds are not at the same point in their
-- frame when it does -- the split one has four bank switches ahead of it -- so
-- cells that are in motion when the shutter opens differ for no reason at all.
-- $9A, the kernel's line counter, differed every frame; $99, a scratch written
-- between two calls to the sprite positioner, differed from frame 96 because
-- the shutter landed between those two calls in one build and after both in
-- the other. Neither was a simulation difference and excluding them would have
-- been treating the symptom.
--
-- Dodge 'Em strobes CXCLR exactly once a frame, at $F249, immediately after
-- the vblank spin and before the picture. That is a point both builds reach
-- with the same work behind them, so it is where the state is compared.
-- Tennis could not do this -- it never strobes CXCLR (its PORTING.md 3.2 is
-- about a gate that silently measured nothing as a result) -- and this port
-- checked that the strobe was there rather than assuming the sibling's problem
-- did or did not apply.
local frame, states, settled = 0, {}, false

_G._det_wait = emu.add_machine_frame_notifier(function()
    settled = true          -- ignore the cold clear's sweep of the whole TIA
end)

_G._det = mem:install_write_tap(0x2C, 0x2C, "cxclr", function(off, data)
    if not settled then return end
    frame = frame + 1
    if frame > FRAMES then return end
    -- A 16-bit sum with a rotate, so a transposition is not invisible the way
    -- a plain sum makes it.
    local c = 0
    for a = 0x80, 0xF8 do
        c = ((c << 1) | (c >> 15)) & 0xFFFF
        c = (c + cell(a)) & 0xFFFF
    end
    states[c] = true
    print(string.format("DET %d %04X", frame, c))
    if frame == FRAMES then
        local n = 0
        for _ in pairs(states) do n = n + 1 end
        print(string.format("DETSUM frames=%d distinct=%d", frame, n))
    end
end)
