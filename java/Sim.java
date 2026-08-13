package battle;

import java.util.ArrayList;

/** Kernel (must match go/sim.go). Integer world, splitmix64, 3 RNG values per player per tick. */
public final class Sim {
    static final int MAP_W = 10_000;
    static final int MAP_H = 10_000;
    static final int PLAYER_HP = 1000;
    static final int HIT_RADIUS = 150;
    static final int PROJ_SPEED = 200;
    static final int PROJ_TTL = 20;
    static final int SKILL_COOLDOWN = 10;
    static final int DOT_TICKS = 5;
    static final int DOT_DAMAGE = 2;
    static final int PROJ_DAMAGE = 8;
    public static final long HASH_OFFSET = 0xCBF29CE484222325L;
    static final long GOLDEN = 0x9E3779B97F4A7C15L;
    static final long MIX_MUL = 0xBF58476D1CE4E5B9L;
    static final long TICK_BUDGET_US = 50_000;
    static final int WARMUP_TICKS = 20;

    public static long mix(long h, long x) {
        x ^= GOLDEN;
        x *= MIX_MUL;
        x ^= x >>> 27;
        h ^= x;
        h *= GOLDEN;
        return h;
    }

    static long mixI32(long h, int v) {
        return mix(h, v & 0xFFFFFFFFL);
    }

    public static Long castMod(String workload) {
        return switch (workload) {
            case "low" -> 50L;
            case "medium" -> 10L;
            case "high" -> 3L;
            case "insane" -> 1L;
            default -> null;
        };
    }

    static Boolean parseAlloc(String s) {
        return switch (s) {
            case "naive" -> false;
            case "arena" -> true;
            default -> null;
        };
    }

    static final class Rng {
        long state;

        Rng(long seed) {
            state = seed;
        }

        long next() {
            state += GOLDEN;
            long z = state;
            z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
            z = (z ^ (z >>> 27)) * 0x94D049BB133366EBL;
            return z ^ (z >>> 31);
        }
    }

    static long roomSeed(long seed, int roomId) {
        return new Rng(seed ^ (Integer.toUnsignedLong(roomId) * GOLDEN)).next();
    }

    static final class Player {
        int id;
        int team;
        int x, y;
        int hp;
        int cooldown;
        boolean alive;
    }

    static final class Projectile {
        int id;
        int ownerId;
        int ownerTeam;
        int x, y;
        int vx, vy;
        int ttl;
        boolean alive;
    }

    static final class Buff {
        int targetId;
        int remaining;
    }

    static final class DamageEvent {
        int targetId;
        int amount;
    }

    static final class Snap {
        int id, x, y, hp, alive;
    }

    public static final class Room {
        final boolean arena;
        final Rng rng;
        final Player[] players;
        final ArrayList<Projectile> projs = new ArrayList<>(64);
        final ArrayList<Buff> buffs = new ArrayList<>(64);
        final ArrayList<DamageEvent> events = new ArrayList<>(64);
        final ArrayList<Projectile> projPool = new ArrayList<>();
        final ArrayList<Buff> buffPool = new ArrayList<>();
        final ArrayList<DamageEvent> eventPool = new ArrayList<>();
        Snap[] snap;
        int nextProjId = 1;
        public long damageTotal;
        public long hash = HASH_OFFSET;

        public Room(long seed, int roomId, int nPlayers, boolean arena) {
            this.arena = arena;
            this.rng = new Rng(roomSeed(seed, roomId));
            this.players = new Player[nPlayers];
            if (arena) {
                snap = new Snap[nPlayers];
                for (int i = 0; i < nPlayers; i++) {
                    snap[i] = new Snap();
                }
            }
            int half = nPlayers / 2;
            for (int i = 0; i < nPlayers; i++) {
                int id = i + 1;
                int team = 1;
                int idxInTeam = i;
                int x = 3500;
                if (id > half) {
                    team = 2;
                    idxInTeam = i - half;
                    x = 6500;
                }
                Player p = new Player();
                p.id = id;
                p.team = team;
                p.x = x;
                p.y = 500 + idxInTeam * 400;
                p.hp = PLAYER_HP;
                p.alive = true;
                players[i] = p;
            }
        }

        public int aliveCount() {
            int n = 0;
            for (Player p : players) {
                if (p.alive) {
                    n++;
                }
            }
            return n;
        }

        public void tick(long cmod) {
            for (int i = 0; i < players.length; i++) {
                Player p = players[i];
                int dx = (int) Long.remainderUnsigned(rng.next(), 7) - 3;
                int dy = (int) Long.remainderUnsigned(rng.next(), 7) - 3;
                boolean want = Long.remainderUnsigned(rng.next(), cmod) == 0;
                if (!p.alive) {
                    continue;
                }
                p.x = clamp(p.x + dx, 0, MAP_W);
                p.y = clamp(p.y + dy, 0, MAP_H);
                if (p.cooldown > 0) {
                    p.cooldown--;
                }
                if (want && p.cooldown == 0) {
                    int tgt = nearestEnemy(i);
                    if (tgt >= 0) {
                        spawnProj(p, players[tgt]);
                        p.cooldown = SKILL_COOLDOWN;
                    }
                }
            }

            if (arena) {
                recycleEvents();
            } else {
                events.clear();
            }
            int nProj = projs.size();
            for (int i = 0; i < nProj; i++) {
                Projectile pr = projs.get(i);
                if (!pr.alive) {
                    continue;
                }
                pr.x = clamp(pr.x + pr.vx, 0, MAP_W);
                pr.y = clamp(pr.y + pr.vy, 0, MAP_H);
                pr.ttl--;
                for (Player t : players) {
                    if (!t.alive || t.team == pr.ownerTeam) {
                        continue;
                    }
                    if (manhattan(pr.x, pr.y, t.x, t.y) <= HIT_RADIUS) {
                        DamageEvent ev = allocEvent();
                        ev.targetId = t.id;
                        ev.amount = PROJ_DAMAGE;
                        events.add(ev);
                        pr.alive = false;
                        break;
                    }
                }
                if (pr.ttl <= 0) {
                    pr.alive = false;
                }
            }
            compactProj();

            for (DamageEvent e : events) {
                applyDamage(e.targetId, e.amount);
                addBuff(e.targetId);
            }

            int nBuff = buffs.size();
            for (int i = 0; i < nBuff; i++) {
                Buff b = buffs.get(i);
                applyDamage(b.targetId, DOT_DAMAGE);
                b.remaining--;
            }
            compactBuff();

            Snap[] buf;
            if (arena) {
                buf = snap;
            } else {
                buf = new Snap[players.length];
                for (int i = 0; i < players.length; i++) {
                    buf[i] = new Snap();
                }
            }
            for (int i = 0; i < players.length; i++) {
                Player p = players[i];
                buf[i].id = p.id;
                buf[i].x = p.x;
                buf[i].y = p.y;
                buf[i].hp = p.hp;
                buf[i].alive = p.alive ? 1 : 0;
            }
            mixWorld(buf);
        }

        private void spawnProj(Player src, Player tgt) {
            int dx = tgt.x - src.x;
            int dy = tgt.y - src.y;
            int vx = 0, vy = 0;
            if (abs(dx) >= abs(dy)) {
                vx = sign(dx) * PROJ_SPEED;
            } else {
                vy = sign(dy) * PROJ_SPEED;
            }
            Projectile p = allocProj();
            p.id = nextProjId++;
            p.ownerId = src.id;
            p.ownerTeam = src.team;
            p.x = src.x;
            p.y = src.y;
            p.vx = vx;
            p.vy = vy;
            p.ttl = PROJ_TTL;
            p.alive = true;
            projs.add(p);
        }

        private Projectile allocProj() {
            if (arena && !projPool.isEmpty()) {
                return projPool.remove(projPool.size() - 1);
            }
            return new Projectile();
        }

        private Buff allocBuff() {
            if (arena && !buffPool.isEmpty()) {
                return buffPool.remove(buffPool.size() - 1);
            }
            return new Buff();
        }

        private DamageEvent allocEvent() {
            if (arena && !eventPool.isEmpty()) {
                return eventPool.remove(eventPool.size() - 1);
            }
            return new DamageEvent();
        }

        private void recycleEvents() {
            if (arena) {
                eventPool.addAll(events);
            }
            events.clear();
        }

        private void compactProj() {
            int n = 0;
            for (int i = 0; i < projs.size(); i++) {
                Projectile p = projs.get(i);
                if (p.alive) {
                    projs.set(n++, p);
                } else if (arena) {
                    projPool.add(p);
                }
            }
            trim(projs, n);
        }

        private void compactBuff() {
            int n = 0;
            for (int i = 0; i < buffs.size(); i++) {
                Buff b = buffs.get(i);
                if (b.remaining > 0) {
                    buffs.set(n++, b);
                } else if (arena) {
                    buffPool.add(b);
                }
            }
            trim(buffs, n);
        }

        private static <T> void trim(ArrayList<T> list, int n) {
            for (int i = list.size() - 1; i >= n; i--) {
                list.remove(i);
            }
        }

        private void applyDamage(int targetId, int amount) {
            Player p = players[targetId - 1];
            if (!p.alive) {
                return;
            }
            p.hp -= amount;
            damageTotal += Integer.toUnsignedLong(amount);
            if (p.hp <= 0) {
                p.hp = 0;
                p.alive = false;
            }
        }

        private void addBuff(int targetId) {
            Buff b = allocBuff();
            b.targetId = targetId;
            b.remaining = DOT_TICKS;
            buffs.add(b);
        }

        private void mixWorld(Snap[] buf) {
            long h = hash;
            for (Snap s : buf) {
                h = mix(h, Integer.toUnsignedLong(s.id));
                h = mixI32(h, s.x);
                h = mixI32(h, s.y);
                h = mixI32(h, s.hp);
                h = mix(h, s.alive);
            }
            for (Player p : players) {
                h = mixI32(h, p.cooldown);
                h = mix(h, p.team);
            }
            for (Projectile pr : projs) {
                h = mix(h, Integer.toUnsignedLong(pr.id));
                h = mixI32(h, pr.x);
                h = mixI32(h, pr.y);
                h = mixI32(h, pr.vx);
                h = mixI32(h, pr.vy);
                h = mixI32(h, pr.ttl);
                h = mix(h, Integer.toUnsignedLong(pr.ownerId));
            }
            for (Buff b : buffs) {
                h = mix(h, Integer.toUnsignedLong(b.targetId));
                h = mixI32(h, b.remaining);
            }
            hash = mix(h, damageTotal);
        }

        private int nearestEnemy(int selfIdx) {
            Player self = players[selfIdx];
            int best = -1;
            int bestDist = 1 << 30;
            int bestId = 0;
            for (int i = 0; i < players.length; i++) {
                Player p = players[i];
                if (!p.alive || p.team == self.team) {
                    continue;
                }
                int d = manhattan(self.x, self.y, p.x, p.y);
                if (best < 0 || d < bestDist || (d == bestDist && p.id < bestId)) {
                    best = i;
                    bestDist = d;
                    bestId = p.id;
                }
            }
            return best;
        }
    }

    static int abs(int v) {
        return v < 0 ? -v : v;
    }

    static int sign(int v) {
        if (v > 0) {
            return 1;
        }
        if (v < 0) {
            return -1;
        }
        return 0;
    }

    static int clamp(int v, int lo, int hi) {
        if (v < lo) {
            return lo;
        }
        if (v > hi) {
            return hi;
        }
        return v;
    }

    static int manhattan(int x1, int y1, int x2, int y2) {
        return abs(x1 - x2) + abs(y1 - y2);
    }
}
