package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"runtime"
	"sort"
	"sync"
	"syscall"
	"time"
)

type config struct {
	seed     uint64
	rooms    int
	players  int
	ticks    int
	workload string
	alloc    string
	arena    bool
	castMod  uint64
}

type goRuntime struct {
	GOVersion    string `json:"go_version"`
	GOMAXPROCS   int    `json:"gomaxprocs"`
	NumGC        uint32 `json:"num_gc"`
	PauseTotalNs uint64 `json:"pause_total_ns"`
	HeapAlloc    uint64 `json:"heap_alloc"`
	HeapSys      uint64 `json:"heap_sys"`
}

type result struct {
	Lang           string    `json:"lang"`
	Alloc          string    `json:"alloc"`
	Ticks          int       `json:"ticks"`
	Seed           uint64    `json:"seed"`
	Rooms          int       `json:"rooms"`
	Players        int       `json:"players"`
	Workload       string    `json:"workload"`
	WorldHash      string    `json:"world_hash"`
	DamageTotal    uint64    `json:"damage_total"`
	AlivePlayers   int       `json:"alive_players"`
	TickP50Us      int64     `json:"tick_p50_us"`
	TickP99Us      int64     `json:"tick_p99_us"`
	TickP999Us     int64     `json:"tick_p999_us"`
	TickMaxUs      int64     `json:"tick_max_us"`
	ComputeP50Us   int64     `json:"compute_p50_us"`
	ComputeP99Us   int64     `json:"compute_p99_us"`
	ComputeP999Us  int64     `json:"compute_p999_us"`
	ComputeMaxUs   int64     `json:"compute_max_us"`
	Missed50ms     int       `json:"missed_50ms"`
	Missed100ms    int       `json:"missed_100ms"`
	Missed200ms    int       `json:"missed_200ms"`
	RSSPeakBytes   uint64    `json:"rss_peak_bytes"`
	CPUSeconds     float64   `json:"cpu_seconds"`
	AllocBytes     uint64    `json:"alloc_bytes"`
	AllocObjects   uint64    `json:"alloc_objects"`
	OS             string    `json:"os"`
	Arch           string    `json:"arch"`
	RoomsParallel  bool      `json:"rooms_parallel"`
	Metric         string    `json:"metric"`
	TickIntervalUs int64     `json:"tick_interval_us"`
	Runtime        goRuntime `json:"runtime"`
}

func parseConfig() (config, error) {
	var cfg config
	flag.Uint64Var(&cfg.seed, "seed", 1234, "PRNG seed")
	flag.IntVar(&cfg.rooms, "rooms", 1, "room count")
	flag.IntVar(&cfg.players, "players", 40, "players per room")
	flag.IntVar(&cfg.ticks, "ticks", 200, "ticks per room")
	flag.StringVar(&cfg.workload, "workload", "medium", "low|medium|high|insane")
	flag.StringVar(&cfg.alloc, "alloc", "naive", "naive|arena")
	flag.Parse()
	if cfg.rooms < 1 || cfg.players < 2 || cfg.ticks < 1 {
		return cfg, fmt.Errorf("rooms, players, ticks must be positive (players >= 2)")
	}
	mod, ok := castMod(cfg.workload)
	if !ok {
		return cfg, fmt.Errorf("unknown workload %q", cfg.workload)
	}
	cfg.castMod = mod
	arena, ok := parseAlloc(cfg.alloc)
	if !ok {
		return cfg, fmt.Errorf("unknown alloc %q", cfg.alloc)
	}
	cfg.arena = arena
	return cfg, nil
}

func percentile(sorted []int64, permille int) int64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := (len(sorted) - 1) * permille / 1000
	return sorted[idx]
}

type tickStats struct {
	p50, p99, p999, max            int64
	missed50, missed100, missed200 int
}

func summarize(samples []int64) tickStats {
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	var s tickStats
	s.p50 = percentile(samples, 500)
	s.p99 = percentile(samples, 990)
	s.p999 = percentile(samples, 999)
	for _, us := range samples {
		if us > s.max {
			s.max = us
		}
		if us > tickBudgetUs {
			s.missed50++
		}
		if us > 100_000 {
			s.missed100++
		}
		if us > 200_000 {
			s.missed200++
		}
	}
	return s
}

func rssPeakBytes(ru syscall.Rusage) uint64 {
	rss := uint64(ru.Maxrss)
	if runtime.GOOS == "linux" {
		rss *= 1024
	}
	return rss
}

func cpuSeconds(ru syscall.Rusage) float64 {
	return float64(ru.Utime.Sec) + float64(ru.Utime.Usec)/1e6 +
		float64(ru.Stime.Sec) + float64(ru.Stime.Usec)/1e6
}

type roomOut struct {
	hash     uint64
	damage   uint64
	alive    int
	lags     []int64
	computes []int64
}

func simulateRoom(cfg config, roomID uint32, start time.Time) roomOut {
	rm := newRoom(cfg.seed, roomID, uint32(cfg.players), cfg.arena)
	skipWarmup := cfg.ticks > warmupTicks
	interval := time.Duration(tickBudgetUs) * time.Microsecond
	lags := make([]int64, 0, cfg.ticks)
	computes := make([]int64, 0, cfg.ticks)
	for t := 0; t < cfg.ticks; t++ {
		due := start.Add(time.Duration(t) * interval)
		if wait := time.Until(due); wait > 0 {
			time.Sleep(wait)
		} else {
			runtime.Gosched()
		}
		t0 := time.Now()
		rm.tick(cfg.castMod)
		done := time.Now()
		lag := done.Sub(due).Microseconds()
		if lag < 0 {
			lag = 0
		}
		compute := done.Sub(t0).Microseconds()
		if !skipWarmup || t >= warmupTicks {
			lags = append(lags, lag)
			computes = append(computes, compute)
		}
	}
	return roomOut{
		hash:     rm.hash,
		damage:   rm.damageTotal,
		alive:    rm.aliveCount(),
		lags:     lags,
		computes: computes,
	}
}

func run(cfg config) result {
	var startMS, endMS runtime.MemStats
	runtime.ReadMemStats(&startMS)

	start := time.Now()
	outs := make([]roomOut, cfg.rooms)
	var wg sync.WaitGroup
	wg.Add(cfg.rooms)
	for i := 0; i < cfg.rooms; i++ {
		go func(i int) {
			defer wg.Done()
			outs[i] = simulateRoom(cfg, uint32(i+1), start)
		}(i)
	}
	wg.Wait()

	lags := make([]int64, 0, cfg.rooms*cfg.ticks)
	computes := make([]int64, 0, cfg.rooms*cfg.ticks)
	worldHash := hashOffset
	var damage uint64
	alive := 0
	for i := range outs {
		worldHash = mix(worldHash, outs[i].hash)
		damage += outs[i].damage
		alive += outs[i].alive
		lags = append(lags, outs[i].lags...)
		computes = append(computes, outs[i].computes...)
	}

	runtime.ReadMemStats(&endMS)
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)

	lagS := summarize(lags)
	compS := summarize(computes)

	return result{
		Lang:           "go",
		Alloc:          cfg.alloc,
		Ticks:          cfg.ticks,
		Seed:           cfg.seed,
		Rooms:          cfg.rooms,
		Players:        cfg.players,
		Workload:       cfg.workload,
		WorldHash:      fmt.Sprintf("%016x", worldHash),
		DamageTotal:    damage,
		AlivePlayers:   alive,
		TickP50Us:      lagS.p50,
		TickP99Us:      lagS.p99,
		TickP999Us:     lagS.p999,
		TickMaxUs:      lagS.max,
		ComputeP50Us:   compS.p50,
		ComputeP99Us:   compS.p99,
		ComputeP999Us:  compS.p999,
		ComputeMaxUs:   compS.max,
		Missed50ms:     lagS.missed50,
		Missed100ms:    lagS.missed100,
		Missed200ms:    lagS.missed200,
		RSSPeakBytes:   rssPeakBytes(ru),
		CPUSeconds:     cpuSeconds(ru),
		AllocBytes:     endMS.TotalAlloc - startMS.TotalAlloc,
		AllocObjects:   endMS.Mallocs - startMS.Mallocs,
		OS:             runtime.GOOS,
		Arch:           runtime.GOARCH,
		RoomsParallel:  true,
		Metric:         "deadline_lag",
		TickIntervalUs: tickBudgetUs,
		Runtime: goRuntime{
			GOVersion:    runtime.Version(),
			GOMAXPROCS:   runtime.GOMAXPROCS(0),
			NumGC:        endMS.NumGC - startMS.NumGC,
			PauseTotalNs: endMS.PauseTotalNs - startMS.PauseTotalNs,
			HeapAlloc:    endMS.HeapAlloc,
			HeapSys:      endMS.HeapSys,
		},
	}
}

func main() {
	cfg, err := parseConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(2)
	}
	out, err := json.MarshalIndent(run(cfg), "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "json: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}
