package battle;

import com.sun.management.OperatingSystemMXBean;
import com.sun.management.ThreadMXBean;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

public final class Main {
    public static void main(String[] args) {
        Config cfg;
        try {
            cfg = parse(args);
        } catch (IllegalArgumentException e) {
            System.err.println(e.getMessage());
            System.exit(2);
            return;
        }
        System.out.println(run(cfg));
    }

    static final class Config {
        long seed = 1234;
        int rooms = 1;
        int players = 40;
        int ticks = 200;
        String workload = "medium";
        String alloc = "naive";
        boolean arena;
        long cmod;
    }

    static Config parse(String[] args) {
        Config cfg = new Config();
        for (int i = 0; i < args.length; i++) {
            if (i + 1 >= args.length) {
                throw new IllegalArgumentException("unknown or incomplete flag");
            }
            String key = args[i];
            String val = args[++i];
            switch (key) {
                case "--seed" -> cfg.seed = Long.parseUnsignedLong(val);
                case "--rooms" -> cfg.rooms = Integer.parseInt(val);
                case "--players" -> cfg.players = Integer.parseInt(val);
                case "--ticks" -> cfg.ticks = Integer.parseInt(val);
                case "--workload" -> cfg.workload = val;
                case "--alloc" -> cfg.alloc = val;
                default -> throw new IllegalArgumentException("unknown or incomplete flag");
            }
        }
        if (cfg.rooms < 1 || cfg.players < 2 || cfg.ticks < 1) {
            throw new IllegalArgumentException("rooms, players, ticks must be positive (players >= 2)");
        }
        Long cmod = Sim.castMod(cfg.workload);
        if (cmod == null) {
            throw new IllegalArgumentException("unknown workload \"" + cfg.workload + "\"");
        }
        Boolean arena = Sim.parseAlloc(cfg.alloc);
        if (arena == null) {
            throw new IllegalArgumentException("unknown alloc \"" + cfg.alloc + "\"");
        }
        cfg.cmod = cmod;
        cfg.arena = arena;
        return cfg;
    }

    static final class RoomOut {
        long hash;
        long damage;
        int alive;
        long[] lags;
        long[] computes;
        long allocBytes;
    }

    static String run(Config cfg) {
        ThreadMXBean tmx = (ThreadMXBean) ManagementFactory.getThreadMXBean();
        if (tmx.isThreadAllocatedMemorySupported()) {
            tmx.setThreadAllocatedMemoryEnabled(true);
        }
        OperatingSystemMXBean osb =
                (OperatingSystemMXBean) ManagementFactory.getOperatingSystemMXBean();
        long cpu0 = osb.getProcessCpuTime();
        long gc0 = gcCount();
        long pause0 = gcTimeMs();

        long startNs = System.nanoTime();
        RoomOut[] outs = new RoomOut[cfg.rooms];
        try (var exec = Executors.newVirtualThreadPerTaskExecutor()) {
            List<Future<RoomOut>> futures = new ArrayList<>(cfg.rooms);
            for (int i = 0; i < cfg.rooms; i++) {
                int roomId = i + 1;
                futures.add(exec.submit(() -> simulateRoom(cfg, roomId, startNs, tmx)));
            }
            for (int i = 0; i < cfg.rooms; i++) {
                try {
                    outs[i] = futures.get(i).get();
                } catch (Exception e) {
                    throw new RuntimeException(e);
                }
            }
        }

        long worldHash = Sim.HASH_OFFSET;
        long damage = 0;
        int alive = 0;
        long allocBytes = 0;
        int nSamp = 0;
        for (RoomOut o : outs) {
            worldHash = Sim.mix(worldHash, o.hash);
            damage += o.damage;
            alive += o.alive;
            allocBytes += o.allocBytes;
            nSamp += o.lags.length;
        }
        long[] lags = new long[nSamp];
        long[] computes = new long[nSamp];
        int k = 0;
        for (RoomOut o : outs) {
            System.arraycopy(o.lags, 0, lags, k, o.lags.length);
            System.arraycopy(o.computes, 0, computes, k, o.computes.length);
            k += o.lags.length;
        }

        TickStats lag = summarize(lags);
        TickStats comp = summarize(computes);
        long cpu1 = osb.getProcessCpuTime();
        double cpuSec = cpu1 > cpu0 && cpu0 >= 0 ? (cpu1 - cpu0) / 1e9 : 0;

        String os = System.getProperty("os.name", "").toLowerCase();
        if (os.contains("mac")) {
            os = "darwin";
        } else if (os.contains("linux")) {
            os = "linux";
        }
        String arch = System.getProperty("os.arch", "");

        StringBuilder sb = new StringBuilder();
        sb.append("{\n");
        fieldS(sb, "lang", "java");
        fieldS(sb, "alloc", cfg.alloc);
        fieldN(sb, "ticks", cfg.ticks);
        fieldN(sb, "seed", cfg.seed);
        fieldN(sb, "rooms", cfg.rooms);
        fieldN(sb, "players", cfg.players);
        fieldS(sb, "workload", cfg.workload);
        fieldS(sb, "world_hash", hex64(worldHash));
        fieldU(sb, "damage_total", damage);
        fieldN(sb, "alive_players", alive);
        fieldN(sb, "tick_p50_us", lag.p50);
        fieldN(sb, "tick_p99_us", lag.p99);
        fieldN(sb, "tick_p999_us", lag.p999);
        fieldN(sb, "tick_max_us", lag.max);
        fieldN(sb, "compute_p50_us", comp.p50);
        fieldN(sb, "compute_p99_us", comp.p99);
        fieldN(sb, "compute_p999_us", comp.p999);
        fieldN(sb, "compute_max_us", comp.max);
        fieldN(sb, "missed_50ms", lag.missed50);
        fieldN(sb, "missed_100ms", lag.missed100);
        fieldN(sb, "missed_200ms", lag.missed200);
        fieldU(sb, "rss_peak_bytes", rssBytes());
        sb.append("  \"cpu_seconds\": ").append(String.format(java.util.Locale.US, "%.6f", cpuSec)).append(",\n");
        fieldU(sb, "alloc_bytes", allocBytes);
        fieldU(sb, "alloc_objects", gcCount() - gc0);
        fieldS(sb, "os", os);
        fieldS(sb, "arch", arch);
        sb.append("  \"rooms_parallel\": true,\n");
        fieldS(sb, "metric", "deadline_lag");
        fieldN(sb, "tick_interval_us", Sim.TICK_BUDGET_US);
        sb.append("  \"runtime\": {");
        sb.append("\"java_version\": \"").append(esc(System.getProperty("java.version", ""))).append("\", ");
        sb.append("\"vm_name\": \"").append(esc(System.getProperty("java.vm.name", ""))).append("\", ");
        sb.append("\"available_processors\": ").append(Runtime.getRuntime().availableProcessors()).append(", ");
        sb.append("\"gc_count\": ").append(gcCount() - gc0).append(", ");
        sb.append("\"gc_time_ms\": ").append(gcTimeMs() - pause0).append(", ");
        sb.append("\"heap_used\": ").append(ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getUsed());
        sb.append("}\n}");
        return sb.toString();
    }

    static RoomOut simulateRoom(Config cfg, int roomId, long startNs, ThreadMXBean tmx) {
        long alloc0 = threadAlloc(tmx);
        Sim.Room room = new Sim.Room(cfg.seed, roomId, cfg.players, cfg.arena);
        boolean skipWarmup = cfg.ticks > Sim.WARMUP_TICKS;
        long intervalNs = Sim.TICK_BUDGET_US * 1_000L;
        int cap = skipWarmup ? cfg.ticks - Sim.WARMUP_TICKS : cfg.ticks;
        long[] lags = new long[Math.max(cap, 0)];
        long[] computes = new long[Math.max(cap, 0)];
        int n = 0;
        for (int t = 0; t < cfg.ticks; t++) {
            long due = startNs + t * intervalNs;
            waitDeadline(due);
            long t0 = System.nanoTime();
            room.tick(cfg.cmod);
            long done = System.nanoTime();
            long lag = Math.max((done - due) / 1_000, 0);
            long compute = (done - t0) / 1_000;
            if (!skipWarmup || t >= Sim.WARMUP_TICKS) {
                lags[n] = lag;
                computes[n] = compute;
                n++;
            }
        }
        RoomOut o = new RoomOut();
        o.hash = room.hash;
        o.damage = room.damageTotal;
        o.alive = room.aliveCount();
        o.lags = lags;
        o.computes = computes;
        o.allocBytes = Math.max(threadAlloc(tmx) - alloc0, 0);
        return o;
    }

    static void waitDeadline(long dueNs) {
        long remaining = dueNs - System.nanoTime();
        if (remaining > 0) {
            long ms = (remaining + 999_999) / 1_000_000;
            if (ms > 0) {
                try {
                    Thread.sleep(ms);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        } else {
            Thread.yield();
        }
    }

    static final class TickStats {
        long p50, p99, p999, max;
        int missed50, missed100, missed200;
    }

    static TickStats summarize(long[] samples) {
        long[] s = samples.clone();
        Arrays.sort(s);
        TickStats t = new TickStats();
        t.p50 = percentile(s, 500);
        t.p99 = percentile(s, 990);
        t.p999 = percentile(s, 999);
        for (long us : s) {
            if (us > t.max) {
                t.max = us;
            }
            if (us > Sim.TICK_BUDGET_US) {
                t.missed50++;
            }
            if (us > 100_000) {
                t.missed100++;
            }
            if (us > 200_000) {
                t.missed200++;
            }
        }
        return t;
    }

    static long percentile(long[] sorted, int permille) {
        if (sorted.length == 0) {
            return 0;
        }
        return sorted[(int) ((sorted.length - 1L) * permille / 1000)];
    }

    static String hex64(long n) {
        String s = Long.toUnsignedString(n, 16);
        return "0".repeat(Math.max(0, 16 - s.length())) + s;
    }

    static long threadAlloc(ThreadMXBean tmx) {
        if (!tmx.isThreadAllocatedMemoryEnabled()) {
            return 0;
        }
        long v = tmx.getCurrentThreadAllocatedBytes();
        return v < 0 ? 0 : v;
    }

    static long gcCount() {
        long n = 0;
        for (GarbageCollectorMXBean b : ManagementFactory.getGarbageCollectorMXBeans()) {
            n += Math.max(b.getCollectionCount(), 0);
        }
        return n;
    }

    static long gcTimeMs() {
        long n = 0;
        for (GarbageCollectorMXBean b : ManagementFactory.getGarbageCollectorMXBeans()) {
            n += Math.max(b.getCollectionTime(), 0);
        }
        return n;
    }

    static long rssBytes() {
        try {
            Process p = new ProcessBuilder("ps", "-o", "rss=", "-p", Long.toString(ProcessHandle.current().pid()))
                    .redirectErrorStream(true)
                    .start();
            String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
            p.waitFor();
            return Long.parseLong(out) * 1024;
        } catch (Exception e) {
            return 0;
        }
    }

    static void fieldS(StringBuilder sb, String k, String v) {
        sb.append("  \"").append(k).append("\": \"").append(esc(v)).append("\",\n");
    }

    static void fieldN(StringBuilder sb, String k, long v) {
        sb.append("  \"").append(k).append("\": ").append(v).append(",\n");
    }

    static void fieldU(StringBuilder sb, String k, long v) {
        sb.append("  \"").append(k).append("\": ").append(Long.toUnsignedString(v)).append(",\n");
    }

    static String esc(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
