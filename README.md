# battle-runtime-benchmark

同一套确定性战斗核，对比 Go / Rust / Zig / Elixir 在 **20Hz 战斗服** 上的到期滞后（deadline lag）。

这不是「四种 GC 对比」。Go 有 tracing GC，Elixir 是按进程的 copying GC，Rust 和 Zig 默认是显式生命周期 / allocator。产品问题只有一句：

> 50ms 一帧的战斗服，会不会偶尔卡一帧？GC 和调度分别把 p99、max 推到哪里？

原始设想在 [`idea.md`](idea.md)。对齐规则写在 [`go/sim.go`](go/sim.go) 顶部；改一边必须改另外三边，再跑 `scripts/compare.sh`。

## 在测什么

每个房间 40 名玩家，整数坐标，无浮点。tick 顺序固定：移动+放技能 → 弹道移动与命中 → 伤害事件 + DoT → 把世界状态 mix 进 `world_hash`。三种寿命的对象都在：玩家（长）、弹道/buff（中）、伤害事件和 snapshot（短）。

没有网络、没有 AOI。一房间一个执行单元：

| 语言 | 执行单元 |
|------|----------|
| Go | 1 goroutine / 房间 |
| Rust | 1 Tokio task / 房间 |
| Zig | skynet 式 worker 池：N 个 OS worker + 全局就绪队列 + 1ms timer；一房间同一时刻只在一个 worker 上跑。不是绿线程。 |
| Elixir | 1 BEAM process / 房间 |

`--alloc naive|arena`：naive 给短对象走堆分配；arena 复用切片。Elixir 没有真正的 arena，两条路径算的是同一套规则，GC 仍然按进程来。

主指标是 **到期 → 做完**，不是「能跑多快」。共享同一个 `start`，第 `t` 帧到期时刻是 `start + t × 50ms`。早到就睡到点；晚到就让出调度（`Gosched` / `yield_now` / 队列尾 / `:erlang.yield`）。

- **lag**（JSON 里 `tick_*`、`missed_*`）：做完时刻 − 到期时刻
- **compute**（`compute_*`）：一次 `tick()` 的墙钟时间
- 前 20 个 tick 只做计算，不进延迟统计

`world_hash` / `damage_total` / `alive_players` 必须跨语言一致。对不上的矩阵作废。

## 怎么测

两类实验，seed 一律 `1234`：

| | 短对比 | 长对比 |
|--|--------|--------|
| 时长 | 2 分钟 / 格（2400 tick） | 30 分钟（36000 tick） |
| 格子 | 朴素/复用 × 100/500/1000 房 × 中等/高压 | 各语言「更好的那套」：复用 + 1000 房高压 |
| 机器 | Mac Mini M4，10 核 | 本机，12 核 |
| 用途 | 看房间数和分配策略怎么把 p99 抬起来 | 看尾巴在浸泡里会不会爆 |

两台机器不能横比绝对值。

```bash
# 先对拍（200 tick 也走真实 50ms 节拍，大约 10 秒 × 8 个二进制）
./scripts/compare.sh 1234 200 medium

# 单次
./go/battle --rooms 1 --players 40 --ticks 200 --seed 1234 --workload medium --alloc arena

# 短矩阵 / 长跑；ONLY=go|rust|zig|elixir 只跑一种语言
ONLY=elixir ./scripts/run_matrix.sh   # → results/matrix_elixir.jsonl
ONLY=elixir ./scripts/run_long.sh     # → results/long_elixir.jsonl
```

新跑次写 `results/`（git 忽略）。要留进仓库就拷进 `archive/`，不要覆盖旧目录。

## 测到了什么

2026-08-13 封存。长跑四方 `world_hash=109d9249dcab5cce`。

**长对比**（本机 12 核，复用，1000 房，高压，30 分钟）：

| 语言 | lag p99 | lag max | 超 50ms | 计算 p99 | RSS | CPU |
|------|---------|---------|---------|----------|-----|-----|
| Go | 5.1ms | **173ms** | **6000**（其中 3000 次 >100ms） | 15µs | 1190MB | 359s |
| Rust | 12.9ms | 24ms | 0 | 15µs | 1179MB | 334s |
| Zig | **4.6ms** | 42ms | 0 | 15µs | 926MB | 459s |
| Elixir | 14.9ms | 131ms | 2257（52 次 >100ms） | **10.9ms** | 2140MB | 4547s† |

† Elixir 的 CPU 是 `:erlang.statistics(:runtime)`，不是 `getrusage`，不能和另外三方直接比秒数。

Go/Rust/Zig 的计算 p99 分不开（都是 15µs），差在 runtime 和调度：Go 日常 p99 好看，尾巴会越过 50ms；Rust 每帧更晚，但 max 封在 24ms；Zig skynet 池日常和尾巴都在预算内，CPU 更贵（1ms timer 轮询）。Elixir 不是「偶发调度尖峰」：一帧 `tick()` 本身就是 10.9ms，lag p99 和 Rust 同一档，尾巴介于 Go 与 Zig 之间。BEAM 上 naive 和 arena 几乎重合。

短对比在 Mini 上。Go 复用、1000 房高压在 2 分钟里就已经出现 max 106ms / 2000 次超预算；Elixir 12 格 hash 全部与同格 Go/Rust 对齐。短跑数字见下方 jsonl，不要和长跑混在一张表里读。

## 结论

虽然这次只覆盖了无网络的确定性内核、1000 房高压、30 分钟浸泡，但是对「20Hz 战斗服会不会卡一帧」这个问题，答案已经分得开：

**会卡，而且卡的原因按语言不一样。** Go/Rust/Zig 算一帧只要 15µs，差的是 runtime 怎么把 1000 个房间塞进 50ms；Elixir 算一帧就要 10.9ms，预算先被内核和进程 GC 吃掉。

按选型读：

1. **不能接受任何一帧超过 50ms** → 这次达标的是 Rust（max 24ms）和 Zig（max 42ms）。Go 和 Elixir 都越线了。
2. **看日常帧（p99）** → Zig 4.6ms ≈ Go 5.1ms，明显好于 Rust 12.9ms ≈ Elixir 14.9ms。Go 的 p99 不能代表它的尾巴。
3. **看最坏一帧** → Rust 24ms < Zig 42ms < Elixir 131ms < Go 173ms。Go 在 30 分钟里有 3000 次超过 100ms；arena 没修好这件事，短跑 2 分钟、1000 房高压就已经爆。所以 Go 的问题更像调度/运行时，不是 malloc。
4. **Elixir 不是「有 GC 所以会偶发卡」的同类项。** 它的 p99 和 Rust 同一档，是因为每帧本来就贵；naive 和 arena 几乎重合，说明 BEAM 上复用切片解决不了 copying + 进程 GC。RSS 约是 Go/Rust 的两倍。
5. **Zig 日常和尾巴都压在预算内，代价是 CPU 更高**（459s vs Go 359s / Rust 334s），而且它是 skynet 式 worker 池，不能当成 goroutine / Tokio task / BEAM process 的同类调度。

换一种说法：同一套战斗规则下，**计算时间三方（Go/Rust/Zig）分不开，分得开的是谁把尾巴按住。** 复用内存能减分配，减不掉 Go 的 173ms 尖峰；按进程 GC 能隔离暂停，减不掉 Elixir 的 10.9ms 计算。

这次没测：真网络、AOI、GOGC 扫描、Zig 绿线程、把 Elixir 内核改成更少拷贝之后还会不会是 10ms。Mini 短跑和本机长跑不能横比绝对值。

## 数据在哪

| 内容 | 路径 |
|------|------|
| Go / Rust 短矩阵 + 长跑 | [`archive/2026-08-13-go-rust-deadline-lag/`](archive/2026-08-13-go-rust-deadline-lag/) |
| Zig 短矩阵 + 长跑 | [`archive/2026-08-13-zig-skynet/`](archive/2026-08-13-zig-skynet/) |
| Elixir 短矩阵 + 长跑 | [`archive/2026-08-13-elixir-beam/`](archive/2026-08-13-elixir-beam/) |
| 各目录说明（机器、工具链、摘要） | 同目录 `NOTES.md` |
| 当场重跑的输出 | `results/`（不入库） |

JSON 里 `metric` 为 `deadline_lag`，`tick_interval_us` 为 `50000`。读延迟用 `tick_p50_us` / `tick_p99_us` / `tick_max_us` / `missed_50ms`；读纯计算用 `compute_*`。
