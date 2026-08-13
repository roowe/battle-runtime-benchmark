mod sim;

use sim::{cast_mod, mix, AllocMode, Room, HASH_OFFSET, TICK_BUDGET_US, WARMUP_TICKS};
use std::alloc::{GlobalAlloc, Layout, System};
use std::env;
use std::process;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

struct CountingAlloc;

static ALLOC_BYTES: AtomicU64 = AtomicU64::new(0);
static ALLOC_OBJS: AtomicU64 = AtomicU64::new(0);

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOC_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
        ALLOC_OBJS.fetch_add(1, Ordering::Relaxed);
        System.alloc(layout)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
    }
}

#[global_allocator]
static GLOBAL: CountingAlloc = CountingAlloc;

struct Config {
    seed: u64,
    rooms: u32,
    players: u32,
    ticks: usize,
    workload: String,
    alloc: AllocMode,
    cast_mod: u64,
}

fn arg_err(msg: &str) -> ! {
    eprintln!("{msg}");
    process::exit(2);
}

fn parse_config() -> Config {
    let mut seed = 1234u64;
    let mut rooms = 1u32;
    let mut players = 40u32;
    let mut ticks = 200usize;
    let mut workload = "medium".to_string();
    let mut alloc = AllocMode::Naive;

    let args: Vec<String> = env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let key = args[i].as_str();
        let val = args.get(i + 1).map(String::as_str);
        match (key, val) {
            ("--seed", Some(v)) => seed = v.parse().unwrap_or_else(|_| arg_err("bad --seed")),
            ("--rooms", Some(v)) => rooms = v.parse().unwrap_or_else(|_| arg_err("bad --rooms")),
            ("--players", Some(v)) => {
                players = v.parse().unwrap_or_else(|_| arg_err("bad --players"))
            }
            ("--ticks", Some(v)) => ticks = v.parse().unwrap_or_else(|_| arg_err("bad --ticks")),
            ("--workload", Some(v)) => workload = v.to_string(),
            ("--alloc", Some(v)) => {
                alloc = AllocMode::parse(v).unwrap_or_else(|| arg_err("unknown --alloc"))
            }
            (k, _) if k.starts_with("--") => arg_err(&format!("unknown or incomplete flag {k}")),
            (k, _) => arg_err(&format!("unexpected argument {k}")),
        }
        i += 2;
    }

    if rooms < 1 || players < 2 || ticks < 1 {
        arg_err("rooms, players, ticks must be positive (players >= 2)");
    }
    let Some(cmod) = cast_mod(&workload) else {
        arg_err(&format!("unknown workload {workload}"));
    };
    Config {
        seed,
        rooms,
        players,
        ticks,
        workload,
        alloc,
        cast_mod: cmod,
    }
}

fn percentile(sorted: &[i64], permille: usize) -> i64 {
    if sorted.is_empty() {
        return 0;
    }
    let idx = (sorted.len() - 1) * permille / 1000;
    sorted[idx]
}

struct TickStats {
    p50: i64,
    p99: i64,
    p999: i64,
    max: i64,
    missed50: i32,
    missed100: i32,
    missed200: i32,
}

fn summarize(mut samples: Vec<i64>) -> TickStats {
    samples.sort_unstable();
    let mut s = TickStats {
        p50: percentile(&samples, 500),
        p99: percentile(&samples, 990),
        p999: percentile(&samples, 999),
        max: 0,
        missed50: 0,
        missed100: 0,
        missed200: 0,
    };
    for us in samples {
        if us > s.max {
            s.max = us;
        }
        if us > TICK_BUDGET_US {
            s.missed50 += 1;
        }
        if us > 100_000 {
            s.missed100 += 1;
        }
        if us > 200_000 {
            s.missed200 += 1;
        }
    }
    s
}

fn rusage() -> libc::rusage {
    unsafe {
        let mut ru: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut ru);
        ru
    }
}

fn rss_peak_bytes(ru: &libc::rusage) -> u64 {
    let mut rss = ru.ru_maxrss as u64;
    if cfg!(target_os = "linux") {
        rss *= 1024;
    }
    rss
}

fn cpu_seconds(ru: &libc::rusage) -> f64 {
    let ut = ru.ru_utime.tv_sec as f64 + ru.ru_utime.tv_usec as f64 / 1e6;
    let st = ru.ru_stime.tv_sec as f64 + ru.ru_stime.tv_usec as f64 / 1e6;
    ut + st
}

struct RoomOut {
    hash: u64,
    damage: u64,
    alive: usize,
    lags: Vec<i64>,
    computes: Vec<i64>,
}

async fn simulate_room(
    seed: u64,
    room_id: u32,
    players: u32,
    alloc: AllocMode,
    ticks: usize,
    cmod: u64,
    start: Instant,
) -> RoomOut {
    let mut room = Room::new(seed, room_id, players, alloc);
    let skip_warmup = ticks > WARMUP_TICKS;
    let interval = Duration::from_micros(TICK_BUDGET_US as u64);
    let mut lags = Vec::with_capacity(ticks);
    let mut computes = Vec::with_capacity(ticks);
    for t in 0..ticks {
        let due = start + interval * (t as u32);
        let now = Instant::now();
        if due > now {
            tokio::time::sleep(due - now).await;
        } else {
            tokio::task::yield_now().await;
        }
        let t0 = Instant::now();
        room.tick(cmod);
        let done = Instant::now();
        let lag = done.saturating_duration_since(due).as_micros() as i64;
        let compute = t0.elapsed().as_micros() as i64;
        if !skip_warmup || t >= WARMUP_TICKS {
            lags.push(lag);
            computes.push(compute);
        }
    }
    RoomOut {
        hash: room.hash,
        damage: room.damage_total,
        alive: room.alive_count(),
        lags,
        computes,
    }
}

async fn run(cfg: &Config) -> String {
    ALLOC_BYTES.store(0, Ordering::Relaxed);
    ALLOC_OBJS.store(0, Ordering::Relaxed);

    let seed = cfg.seed;
    let players = cfg.players;
    let alloc = cfg.alloc;
    let ticks = cfg.ticks;
    let cmod = cfg.cast_mod;
    let start = Instant::now();
    let mut handles = Vec::with_capacity(cfg.rooms as usize);
    for room_id in 1..=cfg.rooms {
        handles.push(tokio::spawn(simulate_room(
            seed, room_id, players, alloc, ticks, cmod, start,
        )));
    }

    let mut outs = Vec::with_capacity(handles.len());
    for h in handles {
        match h.await {
            Ok(out) => outs.push(out),
            Err(err) => {
                eprintln!("room task: {err}");
                process::exit(1);
            }
        }
    }

    let mut lags = Vec::with_capacity(cfg.rooms as usize * cfg.ticks);
    let mut computes = Vec::with_capacity(cfg.rooms as usize * cfg.ticks);
    let mut world_hash = HASH_OFFSET;
    let mut damage = 0u64;
    let mut alive = 0usize;
    for o in &outs {
        world_hash = mix(world_hash, o.hash);
        damage += o.damage;
        alive += o.alive;
        lags.extend_from_slice(&o.lags);
        computes.extend_from_slice(&o.computes);
    }

    let ru = rusage();
    let lag_s = summarize(lags);
    let comp_s = summarize(computes);

    format!(
        "{{\n  \"lang\": \"rust\",\n  \"alloc\": \"{alloc}\",\n  \"ticks\": {ticks},\n  \"seed\": {seed},\n  \"rooms\": {rooms},\n  \"players\": {players},\n  \"workload\": \"{workload}\",\n  \"world_hash\": \"{hash:016x}\",\n  \"damage_total\": {damage},\n  \"alive_players\": {alive},\n  \"tick_p50_us\": {p50},\n  \"tick_p99_us\": {p99},\n  \"tick_p999_us\": {p999},\n  \"tick_max_us\": {max_us},\n  \"compute_p50_us\": {c50},\n  \"compute_p99_us\": {c99},\n  \"compute_p999_us\": {c999},\n  \"compute_max_us\": {cmax},\n  \"missed_50ms\": {m50},\n  \"missed_100ms\": {m100},\n  \"missed_200ms\": {m200},\n  \"rss_peak_bytes\": {rss},\n  \"cpu_seconds\": {cpu:.6},\n  \"alloc_bytes\": {alloc_b},\n  \"alloc_objects\": {alloc_o},\n  \"os\": \"{os}\",\n  \"arch\": \"{arch}\",\n  \"rooms_parallel\": true,\n  \"metric\": \"deadline_lag\",\n  \"tick_interval_us\": {interval},\n  \"runtime\": {{\"scheduler\": \"tokio-multi-thread\", \"worker_threads\": {workers}}}\n}}",
        alloc = cfg.alloc.as_str(),
        ticks = cfg.ticks,
        seed = cfg.seed,
        rooms = cfg.rooms,
        players = cfg.players,
        workload = cfg.workload,
        hash = world_hash,
        alive = alive,
        p50 = lag_s.p50,
        p99 = lag_s.p99,
        p999 = lag_s.p999,
        max_us = lag_s.max,
        c50 = comp_s.p50,
        c99 = comp_s.p99,
        c999 = comp_s.p999,
        cmax = comp_s.max,
        m50 = lag_s.missed50,
        m100 = lag_s.missed100,
        m200 = lag_s.missed200,
        rss = rss_peak_bytes(&ru),
        cpu = cpu_seconds(&ru),
        alloc_b = ALLOC_BYTES.load(Ordering::Relaxed),
        alloc_o = ALLOC_OBJS.load(Ordering::Relaxed),
        os = env::consts::OS,
        arch = env::consts::ARCH,
        interval = TICK_BUDGET_US,
        workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
    )
}

#[tokio::main]
async fn main() {
    let cfg = parse_config();
    println!("{}", run(&cfg).await);
}
