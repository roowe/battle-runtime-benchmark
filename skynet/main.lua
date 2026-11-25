local skynet = require "skynet"

local function parse_args(s)
    local cfg = {}
    for k, v in string.gmatch(s or "", "(%w+)=([^;]+)") do cfg[k] = v end
    return cfg
end

local cfg = parse_args(skynet.getenv("bench_args"))
local rooms = tonumber(cfg.rooms) or 1
local players = tonumber(cfg.players) or 40
local ticks = tonumber(cfg.ticks) or 200
local seed = tonumber(cfg.seed) or 1234
local workload = cfg.workload or "medium"
local alloc = cfg.alloc or "arena"

local room_args = string.format("seed=%d;players=%d;ticks=%d;workload=%s;alloc=%s",
    seed, players, ticks, workload, alloc)

local results = {}
local done = 0

local function hex_to_u64(s)
    local h = 0
    for i = 1, #s do
        local c = s:sub(i, i)
        local d = tonumber(c, 16)
        h = h * 16 + d
    end
    return h
end

local function mix(h, x)
    x = (x ~ 0x9e3779b97f4a7c15) * 0xbf58476d1ce4e5b9
    x = x ~ (x >> 27)
    h = h ~ x
    return h * 0x9e3779b97f4a7c15
end

local function percentile(sorted, n, permille)
    if n == 0 then return 0 end
    local idx = (n - 1) * permille // 1000 + 1
    return sorted[idx]
end

local function proc_self()
    local f = io.open("/proc/self/stat", "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    local fields = {}
    for v in line:gmatch("%S+") do fields[#fields + 1] = v end
    -- utime=14 stime=15 rss(pages)=24
    local cpu = (tonumber(fields[14]) + tonumber(fields[15])) / 100
    local rss = tonumber(fields[24]) * 4096
    return cpu, rss
end

local function finish()
    local lags, comps = {}, {}
    local world = 0xcbf29ce484222325
    local damage, alive = 0, 0
    for id = 1, rooms do
        local x = assert(results[id], "missing room " .. id)
        world = mix(world, hex_to_u64(x.hash))
        damage = damage + x.damage
        alive = alive + x.alive
        for i = 1, #x.lags do lags[#lags + 1] = x.lags[i] end
        for i = 1, #x.comps do comps[#comps + 1] = x.comps[i] end
    end
    table.sort(lags)
    table.sort(comps)

    local p50 = percentile(lags, #lags, 500)
    local p99 = percentile(lags, #lags, 990)
    local p999 = percentile(lags, #lags, 999)
    local max = #lags > 0 and lags[#lags] or 0
    local m50, m100, m200 = 0, 0, 0
    for i = 1, #lags do
        local v = lags[i]
        if v > 50000 then m50 = m50 + 1 end
        if v > 100000 then m100 = m100 + 1 end
        if v > 200000 then m200 = m200 + 1 end
    end
    local cp50 = percentile(comps, #comps, 500)
    local cp99 = percentile(comps, #comps, 990)
    local cp999 = percentile(comps, #comps, 999)
    local cmax = #comps > 0 and comps[#comps] or 0

    local cpu, rss = proc_self()
    local thread = tonumber(skynet.getenv("thread")) or 0

    io.write(string.format([[
{
  "lang": "skynet",
  "alloc": "%s",
  "ticks": %d,
  "seed": %d,
  "rooms": %d,
  "players": %d,
  "workload": "%s",
  "world_hash": "%016x",
  "damage_total": %d,
  "alive_players": %d,
  "tick_p50_us": %d,
  "tick_p99_us": %d,
  "tick_p999_us": %d,
  "tick_max_us": %d,
  "compute_p50_us": %d,
  "compute_p99_us": %d,
  "compute_p999_us": %d,
  "compute_max_us": %d,
  "missed_50ms": %d,
  "missed_100ms": %d,
  "missed_200ms": %d,
  "rss_peak_bytes": %d,
  "cpu_seconds": %.2f,
  "alloc_bytes": 0,
  "alloc_objects": 0,
  "os": "linux",
  "arch": "x64",
  "rooms_parallel": true,
  "metric": "deadline_lag",
  "tick_interval_us": 50000,
  "runtime": {"lua_version": "%s", "skynet_thread": %d, "services": %d, "scheduler": "service-per-room"}
}
]], alloc, ticks, seed, rooms, players, workload, world, damage, alive,
        p50, p99, p999, max, cp50, cp99, cp999, cmax,
        m50, m100, m200, rss or 0, cpu or 0, _VERSION, thread, rooms + 1))
    io.flush()
    os.exit(0)
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, id, hash, damage, alive, lags, comps)
        if cmd == "result" then
            results[id] = { hash = hash, damage = damage, alive = alive, lags = lags, comps = comps }
            done = done + 1
            if done == rooms then finish() end
        end
    end)

    local addrs = {}
    for id = 1, rooms do
        addrs[id] = skynet.newservice("room", id, room_args)
    end

    local now = skynet.hpc()
    local start_ns = math.ceil((now + 300 * 1000000) / 10000000) * 10000000
    local self_addr = skynet.self()
    for id = 1, rooms do
        skynet.send(addrs[id], "lua", "go", start_ns, self_addr)
    end
end)
