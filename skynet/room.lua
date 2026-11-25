-- one skynet service per room; the service coroutine is the tick loop
local skynet = require "skynet"
local sim = require "sim"

local room_id, cfg_s = ...
room_id = tonumber(room_id)
local cfg = {}
for k, v in string.gmatch(cfg_s, "(%w+)=([^;]+)") do cfg[k] = v end

local seed = tonumber(cfg.seed) or 1234
local players = tonumber(cfg.players) or 40
local ticks = tonumber(cfg.ticks) or 200
local arena = cfg.alloc == "arena"
local cmod = assert(sim.cast_mod(cfg.workload or "medium"))

local INTERVAL_NS = 50 * 1000000
local CS_NS = 10 * 1000000
local WARMUP = 20

local function run(start_ns, main_addr)
    local r = sim.new_room(seed, room_id, players, arena)
    local skip_warmup = ticks > WARMUP
    local lags, comps = {}, {}

    -- all rooms share the same absolute start; align to a 10ms skynet tick
    local now = skynet.hpc()
    if now < start_ns then
        local cs = math.ceil((start_ns - now) / CS_NS)
        if cs < 1 then cs = 1 end
        skynet.sleep(cs)
    end

    for t = 0, ticks - 1 do
        local due = start_ns + t * INTERVAL_NS
        if t > 0 then
            local n = skynet.hpc()
            if n < due then
                local cs = math.ceil((due - n) / CS_NS)
                if cs < 1 then cs = 1 end
                skynet.sleep(cs)
            end
        end
        local c0 = skynet.hpc()
        sim.tick(r, cmod)
        local c1 = skynet.hpc()

        local lag = c1 - due
        if lag < 0 then lag = 0 end
        if not skip_warmup or t >= WARMUP then
            lags[#lags + 1] = lag // 1000          -- us
            comps[#comps + 1] = (c1 - c0) // 1000  -- us
        end
    end

    skynet.send(main_addr, "lua", "result", room_id,
        string.format("%016x", r.hash), r.damage, sim.alive_count(r), lags, comps)
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, start_ns, main_addr)
        if cmd == "go" then
            skynet.fork(run, start_ns, main_addr)
        end
    end)
end)
