const std = @import("std");
const sim = @import("sim.zig");
const c = std.c;

const Counting = struct {
    parent: std.mem.Allocator,
    bytes: std.atomic.Value(u64) = .init(0),
    objs: std.atomic.Value(u64) = .init(0),

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr) orelse return null;
        _ = self.bytes.fetchAdd(len, .monotonic);
        _ = self.objs.fetchAdd(1, .monotonic);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

const Config = struct {
    seed: u64 = 1234,
    rooms: u32 = 1,
    players: u32 = 40,
    ticks: usize = 200,
    workload: []const u8 = "medium",
    alloc: sim.AllocMode = .naive,
    cast_mod: u64 = 10,
};

fn argErr(msg: []const u8) noreturn {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(2);
}

fn parseConfig(args: std.process.Args) Config {
    var cfg = Config{};
    var it = std.process.Args.Iterator.init(args);
    _ = it.next();
    while (it.next()) |key| {
        const val = it.next() orelse argErr("unknown or incomplete flag");
        if (std.mem.eql(u8, key, "--seed")) {
            cfg.seed = std.fmt.parseInt(u64, val, 10) catch argErr("bad --seed");
        } else if (std.mem.eql(u8, key, "--rooms")) {
            cfg.rooms = std.fmt.parseInt(u32, val, 10) catch argErr("bad --rooms");
        } else if (std.mem.eql(u8, key, "--players")) {
            cfg.players = std.fmt.parseInt(u32, val, 10) catch argErr("bad --players");
        } else if (std.mem.eql(u8, key, "--ticks")) {
            cfg.ticks = std.fmt.parseInt(usize, val, 10) catch argErr("bad --ticks");
        } else if (std.mem.eql(u8, key, "--workload")) {
            cfg.workload = val;
        } else if (std.mem.eql(u8, key, "--alloc")) {
            cfg.alloc = sim.AllocMode.parse(val) orelse argErr("unknown --alloc");
        } else {
            argErr("unknown or incomplete flag");
        }
    }
    if (cfg.rooms < 1 or cfg.players < 2 or cfg.ticks < 1) {
        argErr("rooms, players, ticks must be positive (players >= 2)");
    }
    cfg.cast_mod = sim.castMod(cfg.workload) orelse argErr("unknown workload");
    return cfg;
}

fn percentile(sorted: []const i64, permille: usize) i64 {
    if (sorted.len == 0) return 0;
    return sorted[(sorted.len - 1) * permille / 1000];
}

const TickStats = struct {
    p50: i64 = 0,
    p99: i64 = 0,
    p999: i64 = 0,
    max: i64 = 0,
    missed50: i32 = 0,
    missed100: i32 = 0,
    missed200: i32 = 0,
};

fn summarize(samples: []i64) TickStats {
    std.mem.sort(i64, samples, {}, std.sort.asc(i64));
    var s = TickStats{
        .p50 = percentile(samples, 500),
        .p99 = percentile(samples, 990),
        .p999 = percentile(samples, 999),
    };
    for (samples) |us| {
        if (us > s.max) s.max = us;
        if (us > sim.TICK_BUDGET_US) s.missed50 += 1;
        if (us > 100_000) s.missed100 += 1;
        if (us > 200_000) s.missed200 += 1;
    }
    return s;
}

fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

const RoomJob = struct {
    room: sim.Room,
    tick_i: usize = 0,
    waiting: bool = false,
    due_ns: i128 = 0,
    lags: std.ArrayList(i64) = .empty,
    computes: std.ArrayList(i64) = .empty,
};

const Sched = struct {
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    worker_cond: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    gpa: std.mem.Allocator,
    jobs: []RoomJob,
    ready: std.ArrayList(usize) = .empty,
    remaining: usize,
    quit: bool = false,
    start_ns: i128,
    interval_ns: i128,
    ticks: usize,
    cmod: u64,
};

fn lock(s: *Sched) void {
    _ = c.pthread_mutex_lock(&s.mutex);
}

fn unlock(s: *Sched) void {
    _ = c.pthread_mutex_unlock(&s.mutex);
}

fn enqueueExpired(s: *Sched, now: i128) void {
    for (s.jobs, 0..) |*job, i| {
        if (job.waiting and job.due_ns <= now) {
            job.waiting = false;
            s.ready.append(s.gpa, i) catch unreachable;
        }
    }
}

fn timerThread(s: *Sched) void {
    while (true) {
        lock(s);
        if (s.quit) {
            unlock(s);
            return;
        }
        enqueueExpired(s, nowNs());
        if (s.ready.items.len > 0) {
            _ = c.pthread_cond_broadcast(&s.worker_cond);
        }
        unlock(s);
        var req: std.c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = c.nanosleep(&req, null);
    }
}

fn processJob(s: *Sched, idx: usize) void {
    const job = &s.jobs[idx];
    const due = s.start_ns + s.interval_ns * @as(i128, @intCast(job.tick_i));
    const t0 = nowNs();
    job.room.tick(s.cmod) catch unreachable;
    const done = nowNs();
    var lag: i64 = @intCast(@divTrunc(done - due, 1000));
    if (lag < 0) lag = 0;
    const compute: i64 = @intCast(@divTrunc(done - t0, 1000));
    const skip_warmup = s.ticks > sim.WARMUP_TICKS;
    if (!skip_warmup or job.tick_i >= sim.WARMUP_TICKS) {
        job.lags.append(s.gpa, lag) catch unreachable;
        job.computes.append(s.gpa, compute) catch unreachable;
    }
    job.tick_i += 1;
}

fn workerThread(s: *Sched) void {
    while (true) {
        lock(s);
        while (s.ready.items.len == 0 and !s.quit) {
            _ = c.pthread_cond_wait(&s.worker_cond, &s.mutex);
        }
        if (s.quit and s.ready.items.len == 0) {
            unlock(s);
            return;
        }
        const idx = s.ready.orderedRemove(0);
        unlock(s);

        processJob(s, idx);

        lock(s);
        const job = &s.jobs[idx];
        if (job.tick_i >= s.ticks) {
            s.remaining -= 1;
            if (s.remaining == 0) {
                s.quit = true;
                _ = c.pthread_cond_broadcast(&s.worker_cond);
            }
        } else {
            const due = s.start_ns + s.interval_ns * @as(i128, @intCast(job.tick_i));
            const now = nowNs();
            if (due <= now) {
                s.ready.append(s.gpa, idx) catch unreachable;
                _ = c.pthread_cond_signal(&s.worker_cond);
            } else {
                job.waiting = true;
                job.due_ns = due;
            }
        }
        unlock(s);
    }
}

fn rssPeakBytes() u64 {
    const ru = std.posix.getrusage(std.c.rusage.SELF);
    var rss: u64 = @intCast(ru.maxrss);
    if (@import("builtin").os.tag == .linux) rss *= 1024;
    return rss;
}

fn cpuSeconds() f64 {
    const ru = std.posix.getrusage(std.c.rusage.SELF);
    const ut = @as(f64, @floatFromInt(ru.utime.sec)) + @as(f64, @floatFromInt(ru.utime.usec)) / 1e6;
    const st = @as(f64, @floatFromInt(ru.stime.sec)) + @as(f64, @floatFromInt(ru.stime.usec)) / 1e6;
    return ut + st;
}

fn run(gpa: std.mem.Allocator, counting: *Counting, cfg: Config) !void {
    const n = cfg.rooms;
    const jobs = try gpa.alloc(RoomJob, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        jobs[i] = .{
            .room = try sim.Room.init(gpa, cfg.seed, i + 1, cfg.players, cfg.alloc),
        };
    }

    var sched = Sched{
        .gpa = gpa,
        .jobs = jobs,
        .remaining = n,
        .start_ns = nowNs(),
        .interval_ns = @as(i128, sim.TICK_BUDGET_US) * 1000,
        .ticks = cfg.ticks,
        .cmod = cfg.cast_mod,
    };
    try sched.ready.ensureTotalCapacity(gpa, n);
    i = 0;
    while (i < n) : (i += 1) {
        try sched.ready.append(gpa, i);
    }

    const workers_n = std.Thread.getCpuCount() catch 1;
    const timer = try std.Thread.spawn(.{}, timerThread, .{&sched});
    const workers = try gpa.alloc(std.Thread, workers_n);
    defer gpa.free(workers);
    for (workers) |*w| {
        w.* = try std.Thread.spawn(.{}, workerThread, .{&sched});
    }
    timer.join();
    for (workers) |w| w.join();

    var lags: std.ArrayList(i64) = .empty;
    defer lags.deinit(gpa);
    var computes: std.ArrayList(i64) = .empty;
    defer computes.deinit(gpa);
    var world_hash: u64 = sim.HASH_OFFSET;
    var damage: u64 = 0;
    var alive: usize = 0;
    for (jobs) |*job| {
        world_hash = sim.mix(world_hash, job.room.hash);
        damage += job.room.damage_total;
        alive += job.room.aliveCount();
        try lags.appendSlice(gpa, job.lags.items);
        try computes.appendSlice(gpa, job.computes.items);
        job.lags.deinit(gpa);
        job.computes.deinit(gpa);
        job.room.deinit();
    }
    gpa.free(jobs);
    sched.ready.deinit(gpa);

    const lag_s = summarize(lags.items);
    const comp_s = summarize(computes.items);
    const rss = rssPeakBytes();
    const cpu = cpuSeconds();
    const os = @tagName(@import("builtin").os.tag);
    const arch = @tagName(@import("builtin").cpu.arch);

    var buf: [2048]u8 = undefined;
    const out = std.fmt.bufPrint(&buf,
        \\{{
        \\  "lang": "zig",
        \\  "alloc": "{s}",
        \\  "ticks": {d},
        \\  "seed": {d},
        \\  "rooms": {d},
        \\  "players": {d},
        \\  "workload": "{s}",
        \\  "world_hash": "{x:0>16}",
        \\  "damage_total": {d},
        \\  "alive_players": {d},
        \\  "tick_p50_us": {d},
        \\  "tick_p99_us": {d},
        \\  "tick_p999_us": {d},
        \\  "tick_max_us": {d},
        \\  "compute_p50_us": {d},
        \\  "compute_p99_us": {d},
        \\  "compute_p999_us": {d},
        \\  "compute_max_us": {d},
        \\  "missed_50ms": {d},
        \\  "missed_100ms": {d},
        \\  "missed_200ms": {d},
        \\  "rss_peak_bytes": {d},
        \\  "cpu_seconds": {d:.6},
        \\  "alloc_bytes": {d},
        \\  "alloc_objects": {d},
        \\  "os": "{s}",
        \\  "arch": "{s}",
        \\  "rooms_parallel": true,
        \\  "metric": "deadline_lag",
        \\  "tick_interval_us": {d},
        \\  "runtime": {{"scheduler": "skynet-worker-pool", "worker_threads": {d}, "timer_tick_us": 1000}}
        \\}}
    , .{
        cfg.alloc.asStr(),
        cfg.ticks,
        cfg.seed,
        cfg.rooms,
        cfg.players,
        cfg.workload,
        world_hash,
        damage,
        alive,
        lag_s.p50,
        lag_s.p99,
        lag_s.p999,
        lag_s.max,
        comp_s.p50,
        comp_s.p99,
        comp_s.p999,
        comp_s.max,
        lag_s.missed50,
        lag_s.missed100,
        lag_s.missed200,
        rss,
        cpu,
        counting.bytes.load(.monotonic),
        counting.objs.load(.monotonic),
        os,
        arch,
        sim.TICK_BUDGET_US,
        workers_n,
    }) catch unreachable;
    _ = std.c.write(1, out.ptr, out.len);
    _ = std.c.write(1, "\n", 1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var counting = Counting{ .parent = std.heap.smp_allocator };
    const gpa = counting.allocator();
    const cfg = parseConfig(init.args);
    try run(gpa, &counting, cfg);
}
