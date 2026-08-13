//! Kernel (must match go/sim.go and rust/src/sim.rs).
//!
//! Integer world, no floats. One splitmix64 stream per room.
//! Each tick, every player consumes exactly 3 RNG values (dx, dy, cast),
//! even if dead. Tick order:
//!   1. movement + skill (spawn projectile; new proj does not move this tick)
//!   2. existing projectiles move, first manhattan hit in player-id order
//!   3. apply DamageEvent list in append order (hp damage + DoT buff)
//!   4. tick buffs in list order, then compact
//!   5. allocate a fresh snapshot and mix into room hash
//!
//! Teams: ids 1..=n/2 team 1 (x=3500), rest team 2 (x=6500).
//! Projectile heading is axis-aligned; |dx| >= |dy| prefers x.

const std = @import("std");

pub const MAP_W: i32 = 10000;
pub const MAP_H: i32 = 10000;
pub const PLAYER_HP: i32 = 1000;
pub const HIT_RADIUS: i32 = 150;
pub const PROJ_SPEED: i32 = 200;
pub const PROJ_TTL: i32 = 20;
pub const SKILL_COOLDOWN: i32 = 10;
pub const DOT_TICKS: i32 = 5;
pub const DOT_DAMAGE: i32 = 2;
pub const PROJ_DAMAGE: i32 = 8;
pub const HASH_OFFSET: u64 = 0xcbf29ce484222325;
pub const GOLDEN: u64 = 0x9e3779b97f4a7c15;
pub const MIX_MUL: u64 = 0xbf58476d1ce4e5b9;
pub const TICK_BUDGET_US: i64 = 50_000;
pub const WARMUP_TICKS: usize = 20;

pub const AllocMode = enum {
    naive,
    arena,

    pub fn parse(s: []const u8) ?AllocMode {
        if (std.mem.eql(u8, s, "naive")) return .naive;
        if (std.mem.eql(u8, s, "arena")) return .arena;
        return null;
    }

    pub fn asStr(self: AllocMode) []const u8 {
        return switch (self) {
            .naive => "naive",
            .arena => "arena",
        };
    }
};

pub fn castMod(workload: []const u8) ?u64 {
    if (std.mem.eql(u8, workload, "low")) return 50;
    if (std.mem.eql(u8, workload, "medium")) return 10;
    if (std.mem.eql(u8, workload, "high")) return 3;
    if (std.mem.eql(u8, workload, "insane")) return 1;
    return null;
}

pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    pub fn next(self: *Rng) u64 {
        self.state +%= GOLDEN;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133366eb;
        return z ^ (z >> 31);
    }
};

pub fn mix(h: u64, x: u64) u64 {
    var xx = x;
    xx ^= GOLDEN;
    xx *%= MIX_MUL;
    xx ^= xx >> 27;
    var hh = h;
    hh ^= xx;
    return hh *% GOLDEN;
}

pub fn mixI32(h: u64, v: i32) u64 {
    return mix(h, @as(u32, @bitCast(v)));
}

fn roomSeed(seed: u64, room_id: u32) u64 {
    var r = Rng.init(seed ^ (@as(u64, room_id) *% GOLDEN));
    return r.next();
}

fn abs32(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn sign32(v: i32) i32 {
    if (v > 0) return 1;
    if (v < 0) return -1;
    return 0;
}

fn clamp32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn manhattan(x1: i32, y1: i32, x2: i32, y2: i32) i32 {
    return abs32(x1 - x2) + abs32(y1 - y2);
}

const Player = struct {
    id: u32,
    team: u8,
    x: i32,
    y: i32,
    hp: i32,
    cooldown: i32,
    alive: bool,
};

const Projectile = struct {
    id: u32,
    owner_id: u32,
    owner_team: u8,
    x: i32,
    y: i32,
    vx: i32,
    vy: i32,
    ttl: i32,
    alive: bool,
};

const Buff = struct {
    target_id: u32,
    remaining: i32,
};

const DamageEvent = struct {
    target_id: u32,
    amount: i32,
};

const Snap = struct {
    id: u32,
    x: i32,
    y: i32,
    hp: i32,
    alive: u8,
};

pub const Room = struct {
    gpa: std.mem.Allocator,
    mode: AllocMode,
    rng: Rng,
    players: []Player,
    proj: std.ArrayList(Projectile),
    proj_box: std.ArrayList(*Projectile),
    buffs: std.ArrayList(Buff),
    buff_box: std.ArrayList(*Buff),
    events: std.ArrayList(DamageEvent),
    snap: std.ArrayList(Snap),
    next_proj_id: u32,
    damage_total: u64,
    hash: u64,

    pub fn init(gpa: std.mem.Allocator, seed: u64, room_id: u32, n_players: u32, mode: AllocMode) !Room {
        const players = try gpa.alloc(Player, n_players);
        const half = n_players / 2;
        var i: u32 = 0;
        while (i < n_players) : (i += 1) {
            const id = i + 1;
            const team: u8, const idx_in_team: u32, const x: i32 = if (id > half)
                .{ 2, i - half, 6500 }
            else
                .{ 1, i, 3500 };
            players[i] = .{
                .id = id,
                .team = team,
                .x = x,
                .y = 500 + @as(i32, @intCast(idx_in_team)) * 400,
                .hp = PLAYER_HP,
                .cooldown = 0,
                .alive = true,
            };
        }

        var room = Room{
            .gpa = gpa,
            .mode = mode,
            .rng = Rng.init(roomSeed(seed, room_id)),
            .players = players,
            .proj = .empty,
            .proj_box = .empty,
            .buffs = .empty,
            .buff_box = .empty,
            .events = .empty,
            .snap = .empty,
            .next_proj_id = 1,
            .damage_total = 0,
            .hash = HASH_OFFSET,
        };
        if (mode == .arena) {
            try room.proj.ensureTotalCapacity(gpa, 64);
            try room.buffs.ensureTotalCapacity(gpa, 64);
            try room.events.ensureTotalCapacity(gpa, 64);
            try room.snap.ensureTotalCapacity(gpa, n_players);
        }
        return room;
    }

    pub fn deinit(self: *Room) void {
        for (self.proj_box.items) |p| self.gpa.destroy(p);
        for (self.buff_box.items) |b| self.gpa.destroy(b);
        self.proj.deinit(self.gpa);
        self.proj_box.deinit(self.gpa);
        self.buffs.deinit(self.gpa);
        self.buff_box.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.snap.deinit(self.gpa);
        self.gpa.free(self.players);
    }

    pub fn aliveCount(self: *const Room) usize {
        var n: usize = 0;
        for (self.players) |p| {
            if (p.alive) n += 1;
        }
        return n;
    }

    fn nearestEnemy(self: *const Room, self_idx: usize) ?usize {
        const s = self.players[self_idx];
        var best: ?usize = null;
        var best_dist: i32 = std.math.maxInt(i32);
        var best_id: u32 = 0;
        for (self.players, 0..) |p, i| {
            if (!p.alive or p.team == s.team) continue;
            const d = manhattan(s.x, s.y, p.x, p.y);
            if (best == null or d < best_dist or (d == best_dist and p.id < best_id)) {
                best = i;
                best_dist = d;
                best_id = p.id;
            }
        }
        return best;
    }

    fn spawnProj(self: *Room, src_idx: usize, tgt_idx: usize) !void {
        const src = self.players[src_idx];
        const tgt = self.players[tgt_idx];
        const dx = tgt.x - src.x;
        const dy = tgt.y - src.y;
        const vx: i32, const vy: i32 = if (abs32(dx) >= abs32(dy))
            .{ sign32(dx) * PROJ_SPEED, 0 }
        else
            .{ 0, sign32(dy) * PROJ_SPEED };
        const p = Projectile{
            .id = self.next_proj_id,
            .owner_id = src.id,
            .owner_team = src.team,
            .x = src.x,
            .y = src.y,
            .vx = vx,
            .vy = vy,
            .ttl = PROJ_TTL,
            .alive = true,
        };
        switch (self.mode) {
            .arena => try self.proj.append(self.gpa, p),
            .naive => {
                const hp = try self.gpa.create(Projectile);
                hp.* = p;
                try self.proj_box.append(self.gpa, hp);
            },
        }
        self.next_proj_id += 1;
    }

    fn applyDamage(self: *Room, target_id: u32, amount: i32) void {
        const p = &self.players[target_id - 1];
        if (!p.alive) return;
        p.hp -= amount;
        self.damage_total += @as(u64, @intCast(amount));
        if (p.hp <= 0) {
            p.hp = 0;
            p.alive = false;
        }
    }

    fn addBuff(self: *Room, target_id: u32) !void {
        const b = Buff{ .target_id = target_id, .remaining = DOT_TICKS };
        switch (self.mode) {
            .arena => try self.buffs.append(self.gpa, b),
            .naive => {
                const hp = try self.gpa.create(Buff);
                hp.* = b;
                try self.buff_box.append(self.gpa, hp);
            },
        }
    }

    fn compactProj(self: *Room) void {
        switch (self.mode) {
            .arena => {
                var n: usize = 0;
                for (self.proj.items) |pr| {
                    if (pr.alive) {
                        self.proj.items[n] = pr;
                        n += 1;
                    }
                }
                self.proj.items.len = n;
            },
            .naive => {
                var n: usize = 0;
                for (self.proj_box.items) |pr| {
                    if (pr.alive) {
                        self.proj_box.items[n] = pr;
                        n += 1;
                    } else {
                        self.gpa.destroy(pr);
                    }
                }
                self.proj_box.items.len = n;
            },
        }
    }

    fn compactBuff(self: *Room) void {
        switch (self.mode) {
            .arena => {
                var n: usize = 0;
                for (self.buffs.items) |b| {
                    if (b.remaining > 0) {
                        self.buffs.items[n] = b;
                        n += 1;
                    }
                }
                self.buffs.items.len = n;
            },
            .naive => {
                var n: usize = 0;
                for (self.buff_box.items) |b| {
                    if (b.remaining > 0) {
                        self.buff_box.items[n] = b;
                        n += 1;
                    } else {
                        self.gpa.destroy(b);
                    }
                }
                self.buff_box.items.len = n;
            },
        }
    }

    pub fn tick(self: *Room, cmod: u64) !void {
        for (self.players, 0..) |*p, i| {
            const dx: i32 = @as(i32, @intCast(self.rng.next() % 7)) - 3;
            const dy: i32 = @as(i32, @intCast(self.rng.next() % 7)) - 3;
            const want = self.rng.next() % cmod == 0;
            if (!p.alive) continue;
            p.x = clamp32(p.x + dx, 0, MAP_W);
            p.y = clamp32(p.y + dy, 0, MAP_H);
            if (p.cooldown > 0) p.cooldown -= 1;
            if (want and p.cooldown == 0) {
                if (self.nearestEnemy(i)) |tgt| {
                    try self.spawnProj(i, tgt);
                    p.cooldown = SKILL_COOLDOWN;
                }
            }
        }

        var naive_events: std.ArrayList(*DamageEvent) = .empty;
        defer {
            for (naive_events.items) |e| self.gpa.destroy(e);
            naive_events.deinit(self.gpa);
        }
        if (self.mode == .arena) self.events.items.len = 0;

        switch (self.mode) {
            .arena => {
                for (self.proj.items) |*pr| {
                    if (!pr.alive) continue;
                    pr.x = clamp32(pr.x + pr.vx, 0, MAP_W);
                    pr.y = clamp32(pr.y + pr.vy, 0, MAP_H);
                    pr.ttl -= 1;
                    for (self.players) |t| {
                        if (!t.alive or t.team == pr.owner_team) continue;
                        if (manhattan(pr.x, pr.y, t.x, t.y) <= HIT_RADIUS) {
                            try self.events.append(self.gpa, .{ .target_id = t.id, .amount = PROJ_DAMAGE });
                            pr.alive = false;
                            break;
                        }
                    }
                    if (pr.ttl <= 0) pr.alive = false;
                }
            },
            .naive => {
                for (self.proj_box.items) |pr| {
                    if (!pr.alive) continue;
                    pr.x = clamp32(pr.x + pr.vx, 0, MAP_W);
                    pr.y = clamp32(pr.y + pr.vy, 0, MAP_H);
                    pr.ttl -= 1;
                    for (self.players) |t| {
                        if (!t.alive or t.team == pr.owner_team) continue;
                        if (manhattan(pr.x, pr.y, t.x, t.y) <= HIT_RADIUS) {
                            const ev = try self.gpa.create(DamageEvent);
                            ev.* = .{ .target_id = t.id, .amount = PROJ_DAMAGE };
                            try naive_events.append(self.gpa, ev);
                            pr.alive = false;
                            break;
                        }
                    }
                    if (pr.ttl <= 0) pr.alive = false;
                }
            },
        }
        self.compactProj();

        switch (self.mode) {
            .arena => {
                for (self.events.items) |e| {
                    self.applyDamage(e.target_id, e.amount);
                    try self.addBuff(e.target_id);
                }
            },
            .naive => {
                for (naive_events.items) |e| {
                    self.applyDamage(e.target_id, e.amount);
                    try self.addBuff(e.target_id);
                }
            },
        }

        switch (self.mode) {
            .arena => {
                for (self.buffs.items) |*b| {
                    self.applyDamage(b.target_id, DOT_DAMAGE);
                    b.remaining -= 1;
                }
            },
            .naive => {
                for (self.buff_box.items) |b| {
                    self.applyDamage(b.target_id, DOT_DAMAGE);
                    b.remaining -= 1;
                }
            },
        }
        self.compactBuff();

        switch (self.mode) {
            .arena => {
                self.snap.items.len = 0;
                for (self.players) |p| {
                    try self.snap.append(self.gpa, .{
                        .id = p.id,
                        .x = p.x,
                        .y = p.y,
                        .hp = p.hp,
                        .alive = if (p.alive) 1 else 0,
                    });
                }
                self.mixWorld(self.snap.items);
            },
            .naive => {
                const snap_buf = try self.gpa.alloc(Snap, self.players.len);
                defer self.gpa.free(snap_buf);
                for (self.players, 0..) |p, i| {
                    snap_buf[i] = .{
                        .id = p.id,
                        .x = p.x,
                        .y = p.y,
                        .hp = p.hp,
                        .alive = if (p.alive) 1 else 0,
                    };
                }
                self.mixWorld(snap_buf);
            },
        }
    }

    fn mixWorld(self: *Room, snap_buf: []const Snap) void {
        var h = self.hash;
        for (snap_buf) |s| {
            h = mix(h, s.id);
            h = mixI32(h, s.x);
            h = mixI32(h, s.y);
            h = mixI32(h, s.hp);
            h = mix(h, s.alive);
        }
        for (self.players) |p| {
            h = mixI32(h, p.cooldown);
            h = mix(h, p.team);
        }
        switch (self.mode) {
            .arena => {
                for (self.proj.items) |pr| h = mixProj(h, pr);
                for (self.buffs.items) |b| {
                    h = mix(h, b.target_id);
                    h = mixI32(h, b.remaining);
                }
            },
            .naive => {
                for (self.proj_box.items) |pr| h = mixProj(h, pr.*);
                for (self.buff_box.items) |b| {
                    h = mix(h, b.target_id);
                    h = mixI32(h, b.remaining);
                }
            },
        }
        h = mix(h, self.damage_total);
        self.hash = h;
    }
};

fn mixProj(h0: u64, pr: Projectile) u64 {
    var h = mix(h0, pr.id);
    h = mixI32(h, pr.x);
    h = mixI32(h, pr.y);
    h = mixI32(h, pr.vx);
    h = mixI32(h, pr.vy);
    h = mixI32(h, pr.ttl);
    return mix(h, pr.owner_id);
}
