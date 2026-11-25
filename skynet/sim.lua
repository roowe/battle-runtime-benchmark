-- Skynet/Lua port of go/sim.go.
--
-- Lua 5.5 integers are 64-bit two's complement: +, -, * wrap mod 2^64, `~` is
-- xor and `>>` is a *logical* right shift. That covers splitmix64 and the hash
-- mix directly. Only unsigned remainder needs care: Lua `%` is floor-mod (the
-- sign follows the divisor), so u64mod() splits the value into 32-bit halves.

local HASH_OFFSET = 0xcbf29ce484222325
local GOLDEN      = 0x9e3779b97f4a7c15
local MIX_MUL     = 0xbf58476d1ce4e5b9
local MIX_MUL2    = 0x94d049bb133366eb

local MAP_W, MAP_H   = 10000, 10000
local PLAYER_HP      = 1000
local HIT_RADIUS     = 150
local PROJ_SPEED     = 200
local PROJ_TTL       = 20
local SKILL_COOLDOWN = 10
local DOT_TICKS      = 5
local DOT_DAMAGE     = 2
local PROJ_DAMAGE    = 8

local POW32 = 4294967296

local function u64mod(x, d)
    local hi = x >> 32                 -- logical shift: 0..2^32-1
    local lo = x & 0xFFFFFFFF
    return ((hi % d) * (POW32 % d) + lo) % d
end

local function next_state(s)
    s = s + GOLDEN
    local z = s
    z = (z ~ (z >> 30)) * MIX_MUL
    z = (z ~ (z >> 27)) * MIX_MUL2
    return s, z ~ (z >> 31)
end

local function mix(h, x)
    x = (x ~ GOLDEN) * MIX_MUL
    x = x ~ (x >> 27)
    h = h ~ x
    return h * GOLDEN
end

local function mix_i32(h, v)
    return mix(h, v & 0xFFFFFFFF)
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function sign(v)
    if v > 0 then return 1 end
    if v < 0 then return -1 end
    return 0
end

local function manhattan(x1, y1, x2, y2)
    local dx = x1 - x2
    local dy = y1 - y2
    if dx < 0 then dx = -dx end
    if dy < 0 then dy = -dy end
    return dx + dy
end

local M = {}

function M.cast_mod(workload)
    if workload == "low" then return 50 end
    if workload == "medium" then return 10 end
    if workload == "high" then return 3 end
    if workload == "insane" then return 1 end
    return nil
end

function M.new_room(seed, room_id, n, arena)
    local s0 = seed ~ (room_id * GOLDEN)
    local s1 = select(2, next_state(s0))

    local r = {
        arena = arena,
        rs = s1,
        n = n,
        hash = HASH_OFFSET,
        damage = 0,
        next_pid = 1,
        pid = {}, px = {}, py = {}, php = {}, pcool = {}, pteam = {}, palive = {},
    }
    local half = n // 2
    for i = 1, n do
        local team, x, idx
        if i <= half then
            team, x, idx = 1, 3500, i - 1
        else
            team, x, idx = 2, 6500, i - half - 1
        end
        r.pid[i] = i
        r.px[i] = x
        r.py[i] = 500 + idx * 400
        r.php[i] = PLAYER_HP
        r.pcool[i] = 0
        r.pteam[i] = team
        r.palive[i] = 1
    end

    if arena then
        r.pn, r.bn, r.en = 0, 0, 0
        r.pr_id, r.pr_own, r.pr_team = {}, {}, {}
        r.pr_x, r.pr_y, r.pr_vx, r.pr_vy = {}, {}, {}, {}
        r.pr_ttl, r.pr_alive = {}, {}
        r.bf_t, r.bf_r = {}, {}
        r.ev_t, r.ev_a = {}, {}
        r.sx, r.sy, r.shp, r.salive = {}, {}, {}, {}
        -- the Go arena starts with cap 64; grow naturally past it
        for i = 1, 64 do
            r.pr_id[i], r.pr_own[i], r.pr_team[i] = 0, 0, 0
            r.pr_x[i], r.pr_y[i], r.pr_vx[i], r.pr_vy[i] = 0, 0, 0, 0
            r.pr_ttl[i], r.pr_alive[i] = 0, 0
            r.bf_t[i], r.bf_r[i] = 0, 0
            r.ev_t[i], r.ev_a[i] = 0, 0
        end
        for i = 1, n do
            r.sx[i], r.sy[i], r.shp[i], r.salive[i] = 0, 0, 0, 0
        end
    else
        r.projs = {}
        r.buffs = {}
    end
    return r
end

local function apply_damage(r, target_id, amount)
    -- ids are 1..n and Lua arrays are 1-based, so id N lives at index N
    local idx = target_id
    if r.palive[idx] == 0 then return end
    local hp = r.php[idx] - amount
    r.php[idx] = hp
    r.damage = r.damage + amount
    if hp <= 0 then
        r.php[idx] = 0
        r.palive[idx] = 0
    end
end

local function nearest_enemy(r, self_idx)
    local px, py, pteam, palive, pid = r.px, r.py, r.pteam, r.palive, r.pid
    local sx, sy, team = px[self_idx], py[self_idx], pteam[self_idx]
    local best, best_dist, best_id = 0, 0x40000000, 0
    for j = 1, r.n do
        if palive[j] ~= 0 and pteam[j] ~= team then
            local d = manhattan(sx, sy, px[j], py[j])
            if best == 0 or d < best_dist or (d == best_dist and pid[j] < best_id) then
                best, best_dist, best_id = j, d, pid[j]
            end
        end
    end
    return best
end

local function spawn_proj(r, src_idx, tgt_idx)
    local dx = r.px[tgt_idx] - r.px[src_idx]
    local dy = r.py[tgt_idx] - r.py[src_idx]
    local adx, ady = dx, dy
    if adx < 0 then adx = -adx end
    if ady < 0 then ady = -ady end
    local vx, vy = 0, 0
    if adx >= ady then vx = sign(dx) * PROJ_SPEED else vy = sign(dy) * PROJ_SPEED end

    if r.arena then
        local i = r.pn + 1
        r.pr_id[i], r.pr_own[i], r.pr_team[i] = r.next_pid, r.pid[src_idx], r.pteam[src_idx]
        r.pr_x[i], r.pr_y[i] = r.px[src_idx], r.py[src_idx]
        r.pr_vx[i], r.pr_vy[i] = vx, vy
        r.pr_ttl[i], r.pr_alive[i] = PROJ_TTL, 1
        r.pn = i
    else
        local list = r.projs
        list[#list + 1] = {
            id = r.next_pid, own = r.pid[src_idx], team = r.pteam[src_idx],
            x = r.px[src_idx], y = r.py[src_idx], vx = vx, vy = vy,
            ttl = PROJ_TTL, alive = true,
        }
    end
    r.next_pid = r.next_pid + 1
end

local function add_buff(r, target_id)
    if r.arena then
        local i = r.bn + 1
        r.bf_t[i], r.bf_r[i] = target_id, DOT_TICKS
        r.bn = i
    else
        local list = r.buffs
        list[#list + 1] = { target = target_id, rem = DOT_TICKS }
    end
end

local function hash_world(r, sx, sy, shp, salive)
    local h = r.hash
    local n = r.n
    for i = 1, n do
        h = mix(h, r.pid[i])
        h = mix_i32(h, sx[i])
        h = mix_i32(h, sy[i])
        h = mix_i32(h, shp[i])
        h = mix(h, salive[i])
    end
    for i = 1, n do
        h = mix_i32(h, r.pcool[i])
        h = mix(h, r.pteam[i])
    end
    if r.arena then
        for i = 1, r.pn do
            h = mix(h, r.pr_id[i])
            h = mix_i32(h, r.pr_x[i])
            h = mix_i32(h, r.pr_y[i])
            h = mix_i32(h, r.pr_vx[i])
            h = mix_i32(h, r.pr_vy[i])
            h = mix_i32(h, r.pr_ttl[i])
            h = mix(h, r.pr_own[i])
        end
        for i = 1, r.bn do
            h = mix(h, r.bf_t[i])
            h = mix_i32(h, r.bf_r[i])
        end
    else
        local projs, buffs = r.projs, r.buffs
        for i = 1, #projs do
            local p = projs[i]
            h = mix(h, p.id)
            h = mix_i32(h, p.x)
            h = mix_i32(h, p.y)
            h = mix_i32(h, p.vx)
            h = mix_i32(h, p.vy)
            h = mix_i32(h, p.ttl)
            h = mix(h, p.own)
        end
        for i = 1, #buffs do
            local b = buffs[i]
            h = mix(h, b.target)
            h = mix_i32(h, b.rem)
        end
    end
    h = mix(h, r.damage)
    r.hash = h
end

local function tick_players(r, cmod)
    local px, py, pcool, palive = r.px, r.py, r.pcool, r.palive
    local n = r.n
    for i = 1, n do
        local s1, v1 = next_state(r.rs)
        local s2, v2 = next_state(s1)
        local s3, v3 = next_state(s2)
        r.rs = s3
        local dx = u64mod(v1, 7) - 3
        local dy = u64mod(v2, 7) - 3
        local want = u64mod(v3, cmod) == 0
        if palive[i] ~= 0 then
            px[i] = clamp(px[i] + dx, 0, MAP_W)
            py[i] = clamp(py[i] + dy, 0, MAP_H)
            if pcool[i] > 0 then pcool[i] = pcool[i] - 1 end
            if want and pcool[i] == 0 then
                local tgt = nearest_enemy(r, i)
                if tgt ~= 0 then
                    spawn_proj(r, i, tgt)
                    pcool[i] = SKILL_COOLDOWN
                end
            end
        end
    end
end

local function tick_arena(r, cmod)
    tick_players(r, cmod)

    local px, py, pteam, palive, pid = r.px, r.py, r.pteam, r.palive, r.pid
    local n = r.n
    r.en = 0

    -- 2. existing + just-spawned projectiles move, first hit wins
    for i = 1, r.pn do
        if r.pr_alive[i] ~= 0 then
            local x = clamp(r.pr_x[i] + r.pr_vx[i], 0, MAP_W)
            local y = clamp(r.pr_y[i] + r.pr_vy[i], 0, MAP_H)
            r.pr_x[i], r.pr_y[i] = x, y
            r.pr_ttl[i] = r.pr_ttl[i] - 1
            local owner_team = r.pr_team[i]
            local hit = false
            for j = 1, n do
                if palive[j] ~= 0 and pteam[j] ~= owner_team
                        and manhattan(x, y, px[j], py[j]) <= HIT_RADIUS then
                    local e = r.en + 1
                    r.ev_t[e], r.ev_a[e] = pid[j], PROJ_DAMAGE
                    r.en = e
                    r.pr_alive[i] = 0
                    hit = true
                    break
                end
            end
            if not hit and r.pr_ttl[i] <= 0 then
                r.pr_alive[i] = 0
            end
        end
    end

    -- compact, preserving order
    local k = 0
    for i = 1, r.pn do
        if r.pr_alive[i] ~= 0 then
            k = k + 1
            if k ~= i then
                r.pr_id[k], r.pr_own[k], r.pr_team[k] = r.pr_id[i], r.pr_own[i], r.pr_team[i]
                r.pr_x[k], r.pr_y[k] = r.pr_x[i], r.pr_y[i]
                r.pr_vx[k], r.pr_vy[k] = r.pr_vx[i], r.pr_vy[i]
                r.pr_ttl[k], r.pr_alive[k] = r.pr_ttl[i], 1
            end
        end
    end
    r.pn = k

    -- 3. damage events in append order
    for i = 1, r.en do
        apply_damage(r, r.ev_t[i], r.ev_a[i])
        add_buff(r, r.ev_t[i])
    end

    -- 4. DoT ticks, then compact
    local nb = r.bn
    for i = 1, nb do
        apply_damage(r, r.bf_t[i], DOT_DAMAGE)
        r.bf_r[i] = r.bf_r[i] - 1
    end
    k = 0
    for i = 1, nb do
        if r.bf_r[i] > 0 then
            k = k + 1
            if k ~= i then r.bf_t[k], r.bf_r[k] = r.bf_t[i], r.bf_r[i] end
        end
    end
    r.bn = k

    -- 5. reuse the snapshot buffers
    local sx, sy, shp, salive = r.sx, r.sy, r.shp, r.salive
    for i = 1, n do
        sx[i], sy[i], shp[i], salive[i] = px[i], py[i], r.php[i], palive[i]
    end
    hash_world(r, sx, sy, shp, salive)
end

local function tick_naive(r, cmod)
    tick_players(r, cmod)

    local px, py, pteam, palive, pid = r.px, r.py, r.pteam, r.palive, r.pid
    local n = r.n
    local events = {}

    for i = 1, #r.projs do
        local p = r.projs[i]
        if p.alive then
            p.x = clamp(p.x + p.vx, 0, MAP_W)
            p.y = clamp(p.y + p.vy, 0, MAP_H)
            p.ttl = p.ttl - 1
            local hit = false
            for j = 1, n do
                if palive[j] ~= 0 and pteam[j] ~= p.team
                        and manhattan(p.x, p.y, px[j], py[j]) <= HIT_RADIUS then
                    events[#events + 1] = { target = pid[j], amount = PROJ_DAMAGE }
                    p.alive = false
                    hit = true
                    break
                end
            end
            if not hit and p.ttl <= 0 then p.alive = false end
        end
    end

    local k = 0
    for i = 1, #r.projs do
        local p = r.projs[i]
        if p.alive then
            k = k + 1
            if k ~= i then r.projs[k] = p end
        end
    end
    for i = k + 1, #r.projs do r.projs[i] = nil end

    for i = 1, #events do
        local e = events[i]
        apply_damage(r, e.target, e.amount)
        add_buff(r, e.target)
    end

    local nb = #r.buffs
    for i = 1, nb do
        local b = r.buffs[i]
        apply_damage(r, b.target, DOT_DAMAGE)
        b.rem = b.rem - 1
    end
    k = 0
    for i = 1, nb do
        local b = r.buffs[i]
        if b.rem > 0 then
            k = k + 1
            if k ~= i then r.buffs[k] = b end
        end
    end
    for i = k + 1, nb do r.buffs[i] = nil end

    -- fresh snapshot arrays every tick: this is the "allocate" path
    local sx, sy, shp, salive = {}, {}, {}, {}
    for i = 1, n do
        sx[i], sy[i], shp[i], salive[i] = px[i], py[i], r.php[i], palive[i]
    end
    hash_world(r, sx, sy, shp, salive)
end

function M.tick(r, cmod)
    if r.arena then
        tick_arena(r, cmod)
    else
        tick_naive(r, cmod)
    end
end

function M.alive_count(r)
    local n = 0
    for i = 1, r.n do
        if r.palive[i] ~= 0 then n = n + 1 end
    end
    return n
end

return M
