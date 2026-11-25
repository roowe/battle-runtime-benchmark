# battle-runtime-benchmark

同一套确定性战斗核，对比 Go / Rust / Zig / Elixir / Java 在 **20Hz 战斗服** 上的到期滞后（deadline lag）。附录包含 Skynet / Lua 的 actor 模型版本。z42 0.7.0 的附加实现单独构建、单独运行，见 [`z42/`](z42/README.md)。

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
| Java | 1 虚拟线程 / 房间（JDK 21+） |
| Skynet（附录） | 1 service（Lua coroutine）/ 房间，跑在 4–8 个 worker 线程上 |

`--alloc naive|arena`：naive 给短对象走堆分配；arena 复用切片。Elixir 和 Java 没有真正的 arena，两条路径算的是同一套规则，对象仍然进 GC。

主指标是 **到期 → 做完**，不是「能跑多快」。共享同一个 `start`，第 `t` 帧到期时刻是 `start + t × 50ms`。早到就睡到点；晚到就让出调度（`Gosched` / `yield_now` / 队列尾 / `:erlang.yield` / `Thread.yield`）。

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
# 先对拍（200 tick 也走真实 50ms 节拍，大约 10 秒 × 每种二进制）
./scripts/compare.sh 1234 200 medium

# 单次
./go/battle --rooms 1 --players 40 --ticks 200 --seed 1234 --workload medium --alloc arena
./java/battle_bench --rooms 1 --ticks 200 --seed 1234 --workload medium --alloc arena

# 短矩阵 / 长跑；ONLY=go|rust|zig|elixir|java 只跑一种语言
ONLY=java ./scripts/run_matrix.sh   # → results/matrix_java.jsonl
ONLY=java ./scripts/run_long.sh     # → results/long_java.jsonl
```

新跑次写 `results/`（git 忽略）。要留进仓库就拷进 `archive/`，不要覆盖旧目录。

## 测到了什么

2026-08-13 封存。长跑五方 `world_hash=109d9249dcab5cce`。

**长对比**（本机 12 核，复用，1000 房，高压，30 分钟）：

| 语言 | lag p99 | lag max | 超 50ms | 计算 p99 | RSS | CPU |
|------|---------|---------|---------|----------|-----|-----|
| Go | 5.1ms | **173ms** | **6000**（其中 3000 次 >100ms） | 15µs | 1190MB | 359s |
| Rust | 12.9ms | 24ms | 0 | 15µs | 1179MB | 334s |
| Zig | **4.6ms** | 42ms | 0 | 15µs | 926MB | 459s |
| Elixir | 14.9ms | 131ms | 2257（52 次 >100ms） | **10.9ms** | 2140MB | 4547s† |
| Java | 11.1ms | 67ms | 1052 | 62µs | 1937MB | 577s |

† Elixir 的 CPU 是 `:erlang.statistics(:runtime)`，不是 `getrusage`，不能和另外四方直接比秒数。

Go/Rust/Zig 的计算 p99 分不开（都是 15µs），差在 runtime 和调度。Java 计算 p99 是 62µs，仍和它们同一量级，不是 Elixir 那种 10ms 内核。Java 日常 p99 11.1ms 靠近 Rust；max 67ms 越了 50ms，但 30 分钟里没有超过 100ms 的帧。RSS 约 1.9GB，靠近 Elixir。

短对比在 Mini 上。Go 复用、1000 房高压在 2 分钟里就已经出现 max 106ms / 2000 次超预算；Java / Elixir 12 格 hash 全部与同格 Go/Rust 对齐。短跑数字见下方 jsonl，不要和长跑混在一张表里读。

## z42（附加实现，单独跑）

[`z42/`](z42/README.md) 是同一套内核的 [z42](https://github.com/z42-lang/z42) 版（0.7.0）。**它不接入 `scripts/compare.sh` / `run_matrix.sh` / `run_long.sh`**，构建、运行、矩阵都在 `z42/` 内闭环（`./run.sh`、`./bench_matrix.sh`）。

`world_hash` / `damage_total` / `alive_players` 与 Go 参考实现逐字节一致（1/2/3/5/100 房、arena/naive、low→insane 共 8 组）。下面是豆包云主机（Linux x64，4 vCPU，glibc 2.35 + 自带 2.39 loader）600 tick、40 人/房、seed 1234 的一组对照，Go 同机同参数：

| 语言 | alloc | 房间 | 线程 | lag p50 | lag p99 | lag max | 超 50ms | 计算 p50 | 计算 p99 | RSS | CPU |
|---|---|---|---|---|---|---|---|---|---|---|---|
| z42 | arena | 1 | 1 | 0.15ms | 0.22ms | 0.36ms | 0 | 139µs | 200µs | 25MB | 1.2s |
| z42 | arena | 100 | 4 | 1.33ms | 3.06ms | 4.64ms | 0 | 94µs | 161µs | 32MB | 9.5s |
| z42 | naive | 100 | 4 | 1.51ms | 4.17ms | 14.8ms | 0 | 107µs | 182µs | 47MB | 9.8s |
| Go | arena | 100 | - | 0.76ms | 1.39ms | 1.85ms | 0 | 5µs | 15µs | 5MB | 0.54s |
| Go | naive | 100 | - | 1.02ms | 2.10ms | 2.96ms | 0 | 9µs | 492µs | 8MB | 0.82s |

1000 房（600 tick、medium、arena）：一房一线程时 1000 个 OS 线程挤 4 核，lag p99 302ms、max 930ms、超预算 16549 次；默认 worker 池只起 4 个线程，同样 `world_hash=b61def3711760a01`，lag p99 25ms、max 38ms、0 次超预算。

读法：z42 0.7.0 的 JIT 计算是 Go 的 12–20 倍（~100µs vs ~5µs），但 100 房仍在 50ms 预算内；naive 的 max 来自 minor GC，arena 的 free-list 复用把它压到 5ms 以内。这台是 4 vCPU 云主机，**不能和上面 Mac Mini / 12 核的数字横比**，只用于验证 z42 实现本身。完整 8 格矩阵在 `z42/` 的 `bench_matrix.sh`，口径和限制见 [`z42/NOTES.md`](z42/NOTES.md)。

## 结论

虽然这次只覆盖了无网络的确定性内核、1000 房高压、30 分钟浸泡，但是对「20Hz 战斗服会不会卡一帧」这个问题，答案已经分得开：

**会卡，而且卡的原因按语言不一样。** Go/Rust/Zig/Java 算一帧都在几十微秒，差的是 runtime 怎么把 1000 个房间塞进 50ms；Elixir 算一帧就要 10.9ms，预算先被内核和进程 GC 吃掉。

按选型读：

1. **不能接受任何一帧超过 50ms** → 这次达标的是 Rust（max 24ms）和 Zig（max 42ms）。Java 67ms、Elixir 131ms、Go 173ms 都越线了。
2. **看日常帧（p99）** → Zig 4.6ms ≈ Go 5.1ms，好于 Java 11.1ms ≈ Rust 12.9ms ≈ Elixir 14.9ms。Go 的 p99 不能代表它的尾巴。
3. **看最坏一帧** → Rust 24ms < Zig 42ms < Java 67ms < Elixir 131ms < Go 173ms。Go 有 3000 次超过 100ms；Java 1052 次超 50ms，但没有超 100ms。arena 没修好 Go 的尖峰。
4. **Java 更像 Go，不像 Elixir。** 计算 p99 62µs，GC 30 分钟里 43 次、累计 85ms，所以 67ms 的 max 不是「一帧算不动」，是虚拟线程/调度尾巴。RSS 1.9GB，接近 Elixir。
5. **Elixir 不是「有 GC 所以会偶发卡」的同类项。** 它的 p99 贵，是因为每帧本来就贵。
6. **Zig 日常和尾巴都压在预算内，代价是 CPU 更高**（459s vs Go 359s / Rust 334s / Java 577s），而且它是 skynet 式 worker 池，不能当成 goroutine / Tokio / BEAM / 虚拟线程的同类调度。

换一种说法：同一套战斗规则下，**计算时间 Go/Rust/Zig/Java 分得开的不多，分得开的是谁把尾巴按住。** 复用内存能减分配，减不掉 Go 的 173ms 尖峰；按进程 GC 能隔离暂停，减不掉 Elixir 的 10.9ms 计算；虚拟线程能把 1000 房跑起来，仍会偶发越过 50ms。

这次没测：真网络、AOI、GOGC / JVM GC 调参、Zig 绿线程、把 Elixir 内核改成更少拷贝之后还会不会是 10ms。Mini 短跑和本机长跑不能横比绝对值。

## 数据在哪

| 内容 | 路径 |
|------|------|
| Go / Rust 短矩阵 + 长跑 | [`archive/2026-08-13-go-rust-deadline-lag/`](archive/2026-08-13-go-rust-deadline-lag/) |
| Zig 短矩阵 + 长跑 | [`archive/2026-08-13-zig-skynet/`](archive/2026-08-13-zig-skynet/) |
| Elixir 短矩阵 + 长跑 | [`archive/2026-08-13-elixir-beam/`](archive/2026-08-13-elixir-beam/) |
| Java 短矩阵 + 长跑 | [`archive/2026-08-13-java-loom/`](archive/2026-08-13-java-loom/) |
| Skynet 短矩阵 + 1000 房 + 同机 Elixir 对照 | [`archive/2026-11-25-doubao-cloud/`](archive/2026-11-25-doubao-cloud/) |
| 各目录说明（机器、工具链、摘要） | 同目录 `NOTES.md` |
| 当场重跑的输出 | `results/`（不入库） |

JSON 里 `metric` 为 `deadline_lag`，`tick_interval_us` 为 `50000`。读延迟用 `tick_p50_us` / `tick_p99_us` / `tick_max_us` / `missed_50ms`；读纯计算用 `compute_*`。

## 附录：Skynet / Lua（2026-11-25，豆包云主机）

不是五方对比的一部分：语言和调度模型都不同，只能单独读。

- 4 vCPU 云主机，skynet `a2c00da` + Lua 5.5，1 房间 = 1 service（coroutine），默认 4 worker。
- 600 tick、40 人、medium：1–100 房 0 次超 50ms，100 房 arena lag p99 8.9ms；计算 p50 96–110µs（Go 4–6µs）。
- 1000 房：4 worker p99 82.4ms、12263 次超预算；8 worker p99 32.4ms、1177 次（0.2%），没有 >100ms。
- 9 组 `world_hash` 与 Go 全部一致；细节和 Lua 64 位取模的坑见 [`skynet/README.md`](skynet/README.md) 和 [`skynet/NOTES.md`](skynet/NOTES.md)。
- 同一台机器上补跑了仓库里的 Elixir（OTP 27 + Elixir 1.18.4，4 scheduler，Task/房）：100 房 lag p99 6.7ms / compute p99 5.15ms；1000 房 lag p99 984.8ms、94% 的 tick 超预算。同样是「一房一个执行单元」，Lua coroutine 的内核 compute p99 比 BEAM process 低约 32 倍（100 房），1000 房时 p99 差 12 倍。内存上 Elixir 的 live 房间状态只有 66MB（1000 房，GC 后进程堆求和），531MB RSS 里约 87% 是分配器保留、样本数组和共享代码。
