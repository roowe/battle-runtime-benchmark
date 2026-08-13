//! Kernel (must match go/sim.rs):
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

#[derive(Clone, Copy)]
pub struct Rng {
    state: u64,
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    pub fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(GOLDEN);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133366eb);
        z ^ (z >> 31)
    }
}

pub fn mix(h: u64, x: u64) -> u64 {
    let mut x = x;
    x ^= GOLDEN;
    x = x.wrapping_mul(MIX_MUL);
    x ^= x >> 27;
    let mut h = h;
    h ^= x;
    h.wrapping_mul(GOLDEN)
}

pub fn mix_i32(h: u64, v: i32) -> u64 {
    mix(h, v as u32 as u64)
}

fn room_seed(seed: u64, room_id: u32) -> u64 {
    let mut r = Rng::new(seed ^ (u64::from(room_id).wrapping_mul(GOLDEN)));
    r.next()
}

fn abs32(v: i32) -> i32 {
    if v < 0 {
        -v
    } else {
        v
    }
}

fn sign32(v: i32) -> i32 {
    match v {
        v if v > 0 => 1,
        v if v < 0 => -1,
        _ => 0,
    }
}

fn clamp32(v: i32, lo: i32, hi: i32) -> i32 {
    if v < lo {
        lo
    } else if v > hi {
        hi
    } else {
        v
    }
}

fn manhattan(x1: i32, y1: i32, x2: i32, y2: i32) -> i32 {
    abs32(x1 - x2) + abs32(y1 - y2)
}

pub fn cast_mod(workload: &str) -> Option<u64> {
    match workload {
        "low" => Some(50),
        "medium" => Some(10),
        "high" => Some(3),
        "insane" => Some(1),
        _ => None,
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum AllocMode {
    Naive,
    Arena,
}

impl AllocMode {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "naive" => Some(Self::Naive),
            "arena" => Some(Self::Arena),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Naive => "naive",
            Self::Arena => "arena",
        }
    }
}

#[derive(Clone, Copy)]
struct Player {
    id: u32,
    team: u8,
    x: i32,
    y: i32,
    hp: i32,
    cooldown: i32,
    alive: bool,
}

struct Projectile {
    id: u32,
    owner_id: u32,
    owner_team: u8,
    x: i32,
    y: i32,
    vx: i32,
    vy: i32,
    ttl: i32,
    alive: bool,
}

struct Buff {
    target_id: u32,
    remaining: i32,
}

struct DamageEvent {
    target_id: u32,
    amount: i32,
}

struct Snap {
    id: u32,
    x: i32,
    y: i32,
    hp: i32,
    alive: u8,
}

pub struct Room {
    mode: AllocMode,
    rng: Rng,
    players: Vec<Player>,
    proj: Vec<Projectile>,
    proj_box: Vec<Box<Projectile>>,
    buffs: Vec<Buff>,
    buff_box: Vec<Box<Buff>>,
    events: Vec<DamageEvent>,
    snap: Vec<Snap>,
    next_proj_id: u32,
    pub damage_total: u64,
    pub hash: u64,
}

impl Room {
    pub fn new(seed: u64, room_id: u32, n_players: u32, mode: AllocMode) -> Self {
        let half = n_players / 2;
        let mut players = Vec::with_capacity(n_players as usize);
        for i in 0..n_players {
            let id = i + 1;
            let (team, idx_in_team, x) = if id > half {
                (2u8, i - half, 6500)
            } else {
                (1u8, i, 3500)
            };
            players.push(Player {
                id,
                team,
                x,
                y: 500 + idx_in_team as i32 * 400,
                hp: PLAYER_HP,
                cooldown: 0,
                alive: true,
            });
        }
        let arena = mode == AllocMode::Arena;
        Self {
            mode,
            rng: Rng::new(room_seed(seed, room_id)),
            players,
            proj: if arena {
                Vec::with_capacity(64)
            } else {
                Vec::new()
            },
            proj_box: Vec::new(),
            buffs: if arena {
                Vec::with_capacity(64)
            } else {
                Vec::new()
            },
            buff_box: Vec::new(),
            events: if arena {
                Vec::with_capacity(64)
            } else {
                Vec::new()
            },
            snap: Vec::with_capacity(n_players as usize),
            next_proj_id: 1,
            damage_total: 0,
            hash: HASH_OFFSET,
        }
    }

    pub fn alive_count(&self) -> usize {
        self.players.iter().filter(|p| p.alive).count()
    }

    fn nearest_enemy(&self, self_idx: usize) -> Option<usize> {
        let s = self.players[self_idx];
        let mut best: Option<usize> = None;
        let mut best_dist = i32::MAX;
        let mut best_id = 0u32;
        for (i, p) in self.players.iter().enumerate() {
            if !p.alive || p.team == s.team {
                continue;
            }
            let d = manhattan(s.x, s.y, p.x, p.y);
            if best.is_none() || d < best_dist || (d == best_dist && p.id < best_id) {
                best = Some(i);
                best_dist = d;
                best_id = p.id;
            }
        }
        best
    }

    fn spawn_proj(&mut self, src_idx: usize, tgt_idx: usize) {
        let src = self.players[src_idx];
        let tgt = self.players[tgt_idx];
        let dx = tgt.x - src.x;
        let dy = tgt.y - src.y;
        let (vx, vy) = if abs32(dx) >= abs32(dy) {
            (sign32(dx) * PROJ_SPEED, 0)
        } else {
            (0, sign32(dy) * PROJ_SPEED)
        };
        let p = Projectile {
            id: self.next_proj_id,
            owner_id: src.id,
            owner_team: src.team,
            x: src.x,
            y: src.y,
            vx,
            vy,
            ttl: PROJ_TTL,
            alive: true,
        };
        match self.mode {
            AllocMode::Arena => self.proj.push(p),
            AllocMode::Naive => self.proj_box.push(Box::new(p)),
        }
        self.next_proj_id += 1;
    }

    fn apply_damage(&mut self, target_id: u32, amount: i32) {
        let p = &mut self.players[target_id as usize - 1];
        if !p.alive {
            return;
        }
        p.hp -= amount;
        self.damage_total += amount as u64;
        if p.hp <= 0 {
            p.hp = 0;
            p.alive = false;
        }
    }

    fn add_buff(&mut self, target_id: u32) {
        let b = Buff {
            target_id,
            remaining: DOT_TICKS,
        };
        match self.mode {
            AllocMode::Arena => self.buffs.push(b),
            AllocMode::Naive => self.buff_box.push(Box::new(b)),
        }
    }

    pub fn tick(&mut self, cmod: u64) {
        for i in 0..self.players.len() {
            let dx = (self.rng.next() % 7) as i32 - 3;
            let dy = (self.rng.next() % 7) as i32 - 3;
            let want = self.rng.next() % cmod == 0;
            if !self.players[i].alive {
                continue;
            }
            self.players[i].x = clamp32(self.players[i].x + dx, 0, MAP_W);
            self.players[i].y = clamp32(self.players[i].y + dy, 0, MAP_H);
            if self.players[i].cooldown > 0 {
                self.players[i].cooldown -= 1;
            }
            if want && self.players[i].cooldown == 0 {
                if let Some(tgt) = self.nearest_enemy(i) {
                    self.spawn_proj(i, tgt);
                    self.players[i].cooldown = SKILL_COOLDOWN;
                }
            }
        }

        let mut naive_events: Vec<Box<DamageEvent>> = Vec::new();
        if self.mode == AllocMode::Arena {
            self.events.clear();
        }
        match self.mode {
            AllocMode::Arena => {
                for pr in &mut self.proj {
                    if !pr.alive {
                        continue;
                    }
                    pr.x = clamp32(pr.x + pr.vx, 0, MAP_W);
                    pr.y = clamp32(pr.y + pr.vy, 0, MAP_H);
                    pr.ttl -= 1;
                    for t in &self.players {
                        if !t.alive || t.team == pr.owner_team {
                            continue;
                        }
                        if manhattan(pr.x, pr.y, t.x, t.y) <= HIT_RADIUS {
                            self.events.push(DamageEvent {
                                target_id: t.id,
                                amount: PROJ_DAMAGE,
                            });
                            pr.alive = false;
                            break;
                        }
                    }
                    if pr.ttl <= 0 {
                        pr.alive = false;
                    }
                }
                self.proj.retain(|p| p.alive);
            }
            AllocMode::Naive => {
                for pr in &mut self.proj_box {
                    if !pr.alive {
                        continue;
                    }
                    pr.x = clamp32(pr.x + pr.vx, 0, MAP_W);
                    pr.y = clamp32(pr.y + pr.vy, 0, MAP_H);
                    pr.ttl -= 1;
                    for t in &self.players {
                        if !t.alive || t.team == pr.owner_team {
                            continue;
                        }
                        if manhattan(pr.x, pr.y, t.x, t.y) <= HIT_RADIUS {
                            naive_events.push(Box::new(DamageEvent {
                                target_id: t.id,
                                amount: PROJ_DAMAGE,
                            }));
                            pr.alive = false;
                            break;
                        }
                    }
                    if pr.ttl <= 0 {
                        pr.alive = false;
                    }
                }
                self.proj_box.retain(|p| p.alive);
            }
        }

        let hits: Vec<(u32, i32)> = match self.mode {
            AllocMode::Arena => self
                .events
                .iter()
                .map(|e| (e.target_id, e.amount))
                .collect(),
            AllocMode::Naive => naive_events
                .iter()
                .map(|e| (e.target_id, e.amount))
                .collect(),
        };
        for (target_id, amount) in hits {
            self.apply_damage(target_id, amount);
            self.add_buff(target_id);
        }

        let dots: Vec<u32> = match self.mode {
            AllocMode::Arena => self.buffs.iter().map(|b| b.target_id).collect(),
            AllocMode::Naive => self.buff_box.iter().map(|b| b.target_id).collect(),
        };
        for target_id in dots {
            self.apply_damage(target_id, DOT_DAMAGE);
        }
        match self.mode {
            AllocMode::Arena => {
                for b in &mut self.buffs {
                    b.remaining -= 1;
                }
                self.buffs.retain(|b| b.remaining > 0);
            }
            AllocMode::Naive => {
                for b in &mut self.buff_box {
                    b.remaining -= 1;
                }
                self.buff_box.retain(|b| b.remaining > 0);
            }
        }

        match self.mode {
            AllocMode::Arena => {
                self.snap.clear();
                for p in &self.players {
                    self.snap.push(Snap {
                        id: p.id,
                        x: p.x,
                        y: p.y,
                        hp: p.hp,
                        alive: u8::from(p.alive),
                    });
                }
                let snap = std::mem::take(&mut self.snap);
                self.mix_world(&snap);
                self.snap = snap;
            }
            AllocMode::Naive => {
                let snap_buf: Vec<Snap> = self
                    .players
                    .iter()
                    .map(|p| Snap {
                        id: p.id,
                        x: p.x,
                        y: p.y,
                        hp: p.hp,
                        alive: u8::from(p.alive),
                    })
                    .collect();
                self.mix_world(&snap_buf);
            }
        }
    }

    fn mix_world(&mut self, snap_buf: &[Snap]) {
        let mut h = self.hash;
        for s in snap_buf {
            h = mix(h, u64::from(s.id));
            h = mix_i32(h, s.x);
            h = mix_i32(h, s.y);
            h = mix_i32(h, s.hp);
            h = mix(h, u64::from(s.alive));
        }
        for p in &self.players {
            h = mix_i32(h, p.cooldown);
            h = mix(h, u64::from(p.team));
        }
        match self.mode {
            AllocMode::Arena => {
                for pr in &self.proj {
                    h = mix_proj(h, pr);
                }
                for b in &self.buffs {
                    h = mix(h, u64::from(b.target_id));
                    h = mix_i32(h, b.remaining);
                }
            }
            AllocMode::Naive => {
                for pr in &self.proj_box {
                    h = mix_proj(h, pr);
                }
                for b in &self.buff_box {
                    h = mix(h, u64::from(b.target_id));
                    h = mix_i32(h, b.remaining);
                }
            }
        }
        h = mix(h, self.damage_total);
        self.hash = h;
    }
}

fn mix_proj(mut h: u64, pr: &Projectile) -> u64 {
    h = mix(h, u64::from(pr.id));
    h = mix_i32(h, pr.x);
    h = mix_i32(h, pr.y);
    h = mix_i32(h, pr.vx);
    h = mix_i32(h, pr.vy);
    h = mix_i32(h, pr.ttl);
    mix(h, u64::from(pr.owner_id))
}
