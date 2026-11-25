# skynet（Lua）战斗内核基准

用 [cloudwu/skynet](https://github.com/cloudwu/skynet) 跑同一套确定性战斗核：**一个房间一个 skynet service**，service 是 Lua coroutine，跑在固定数量的 OS worker 线程上。1000 房也不会变成 1000 个线程。

规则与 [`../go/sim.go`](../go/sim.go) 顶部一致，`world_hash` / `damage_total` / `alive_players` 与同机 Go 逐字节对齐。

**独立目录，不接入 `../scripts/`。** 构建、运行、矩阵都在本目录闭环。

## 结论

- 计算 p50 **96–110µs**（Go 同机 4–6µs，约 18 倍）；Lua 解释执行是主要成本，不是分配。
- 1–100 房都在 50ms 预算内：100 房 p99 8.9ms、0 次超预算。
- 1000 房默认 4 线程压不住：p99 82ms、600k 个 tick 里 12263 次超 50ms（2%）。`SKYNET_THREAD=8` 后 p99 32ms、超预算 1177 次（0.2%）、没有 >100ms 的帧。
- 1000 房的失败点和 z42 的 1000 线程不一样：这里不是线程爆炸，是 4 个 worker 上 1000 个 coroutine 的排队 + 10ms 定时器粒度 + Lua GC。
- 同机 Elixir 对照（同 4 scheduler、Task/房）：100 房 compute p99 5.1ms（skynet 159µs）；1000 房 p99 984.8ms、94% 的 tick 超预算。BEAM 在这个负载下先被调度/进程 GC 拖垮，见下文。

## 线程模型

| 项目 | 设置 |
|---|---|
| 执行单元 | 1 个 skynet service（Lua coroutine）/ 房间 |
| worker 线程 | `thread` 配置，默认 4（本机 vCPU 数）；`SKYNET_THREAD` 可改 |
| 计时 | `skynet.hpc()`（CLOCK_MONOTONIC，ns）测完成时刻与 compute |
| 节拍 | `skynet.sleep(ceil(剩余/10ms))`，skynet 定时器单位是 1/100s |

所有房间共享同一个绝对 `start`，第 t 帧到期 = `start + t × 50ms`；早到就睡，晚到就直接算。前 20 个 tick 不进统计，和 Go 一致。

**注意 skynet 定时器是 10ms 一格**：`sleep` 只能按 centisecond 睡，所以 lag 里天然含 0–10ms 的定时器粒度（1 房 p50 1.4ms、100 房 p50 5.5ms 主要来自这里）。纯内核成本看 `compute_*`，它用 ns 计数器单独夹出来。

## 安装 skynet

```bash
git clone --depth 1 https://github.com/cloudwu/skynet.git "$HOME/skynet"
cd "$HOME/skynet" && make -j4 linux
```

依赖 gcc / make。skynet 自带 Lua 5.5（64 位整数、逻辑右移），**不要换 LuaJIT**：LuaJIT 的数字是 double，64 位 hash 语义直接崩。

`run.sh` 默认 `SKYNET_ROOT=$HOME/skynet`，可用环境变量覆盖。

## 跑

```bash
cd skynet
./run.sh "rooms=100;players=40;ticks=600;seed=1234;workload=medium;alloc=arena"

# 1000 房，8 个 worker
SKYNET_THREAD=8 ./run.sh "rooms=1000;players=40;ticks=600;seed=1234;workload=medium;alloc=arena"

# 8 格矩阵 → results/matrix_skynet.jsonl
ROOMS="1 10 50 100" ALLOCS="arena naive" WORKLOAD=medium TICKS=600 ./bench_matrix.sh
```

`run.sh` 会生成临时 skynet 配置（含 `lualoader`，少了这个键 skynet 会静默起不来），然后 `exec skynet <config>`。结果是一段 JSON 打到 stdout。

## 正确性

seed 1234，与同机 Go 完全一致（`world_hash` / `damage_total` / `alive_players`）：

| rooms | players | ticks | workload | alloc | world_hash | damage | alive |
|---|---|---|---|---|---|---|---|
| 1 | 40 | 200 | medium | arena | `ad2d471bee2634ea` | 6778 | 40 |
| 1 | 40 | 200 | medium | naive | `ad2d471bee2634ea` | 6778 | 40 |
| 2 | 12 | 300 | low | naive | `0f5779d90da61806` | 2224 | 24 |
| 3 | 40 | 200 | high | arena | `ba4a9e097e079029` | 33762 | 120 |
| 5 | 40 | 400 | medium | arena | `d13ef926b723e826` | 72640 | 200 |
| 1 | 40 | 1000 | insane | arena | `0114bd6be92d4baf` | 39004 | 6 |
| 10 | 40 | 600 | medium | arena | `593bcc888f35ecbd` | 210712 | 400 |
| 100 | 40 | 600 | medium | arena | `b9db0993d8d999dd` | 2100586 | 4000 |
| 1000 | 40 | 600 | medium | arena | `b61def3711760a01` | 20960766 | 40000 |

## 本机结果（豆包云主机，4 vCPU）

600 tick、40 人、medium、`--spin` 无（skynet 没有忙等），默认 4 worker：

| alloc | 房间 | lag p50 | lag p99 | lag max | 超 50ms | compute p50 | compute p99 | RSS | CPU |
|---|---|---|---|---|---|---|---|---|---|
| arena | 1 | 1.42ms | 2.70ms | 2.7ms | 0 | 110µs | 175µs | 14MB | 0.26s |
| naive | 1 | 1.50ms | 2.74ms | 2.8ms | 0 | 153µs | 250µs | 15MB | 0.30s |
| arena | 10 | 1.97ms | 4.73ms | 9.6ms | 0 | 100µs | 335µs | 16MB | 0.94s |
| naive | 10 | 2.14ms | 3.89ms | 11.2ms | 0 | 121µs | 225µs | 17MB | 1.02s |
| arena | 50 | 3.74ms | 6.30ms | 7.3ms | 0 | 97µs | 149µs | 21MB | 3.43s |
| naive | 50 | 4.28ms | 7.46ms | 19.1ms | 0 | 116µs | 292µs | 26MB | 4.34s |
| arena | 100 | 5.46ms | 8.85ms | 13.0ms | 0 | 98µs | 159µs | 28MB | 6.84s |
| naive | 100 | 5.99ms | 9.56ms | 11.8ms | 0 | 115µs | 194µs | 36MB | 8.10s |
| Go arena | 100 | 0.71ms | 1.82ms | 6.2ms | 0 | 4µs | — | 4.3MB | 0.49s |

1000 房、600 tick、medium、arena（同一个 `world_hash=b61def3711760a01`）：

| 版本 | lag p50 | lag p99 | lag p999 | lag max | 超 50ms | compute p99 | RSS | CPU |
|---|---|---|---|---|---|---|---|---|
| 4 worker（默认） | 15.7ms | **82.4ms** | 127.7ms | **146.5ms** | **12263** | 253µs | 146MB | 68.4s |
| 8 worker | 15.4ms | 32.4ms | 64.4ms | 90.9ms | 1177 | 207µs | 156MB | 66.7s |
| Elixir（4 scheduler） | 224.7ms | **984.8ms** | 1234.9ms | **1559.3ms** | **564776**（94%） | 42.5ms | 531MB | 119.5s |
| Go 对照 | 1.51ms | 2.65ms | — | 3.19ms | 0 | — | 31.9MB | 3.83s |

1000 房 8 worker 仍有 0.2% 的帧超预算，p999 64ms：不是内核算不动（compute p99 207µs），是 1000 个 coroutine 在同一 10ms 边界醒来后的排队和偶发 GC。

**这台是 4 vCPU 云主机，和仓库里 Mac Mini M4 / 12 核的历史数据不能横比。**

## 同机 Elixir 对照（同一台 4 vCPU）

同仓库 `../elixir`，OTP 27 + Elixir 1.18.4，默认 4 个 scheduler，1 个 `Task` / 房间，`player_store=tuple`，600 tick、medium、arena：

| 房间 | Elixir lag p50 | Elixir lag p99 | Elixir compute p50 | Elixir compute p99 | Skynet lag p99 | Skynet compute p99 |
|---|---|---|---|---|---|---|---|
| 1 | 1.56ms | 1.90ms | 245µs | 500µs | 2.70ms | 175µs |
| 10 | 1.45ms | 1.69ms | 405µs | 630µs | 4.73ms | 335µs |
| 50 | 2.50ms | 3.72ms | 984µs | 2.35ms | 6.30ms | 149µs |
| 100 | 4.47ms | 6.73ms | 2.56ms | 5.15ms | 8.85ms | 159µs |
| 1000 | 224.7ms | 984.8ms | 42.5ms | 52.5ms | 82.4ms（4 worker）/ 32.4ms（8 worker） | 253µs |

读法：

- **1–100 房 Elixir 的 lag 更低，但 compute 更贵。** Elixir 用 `Process.sleep(ms)`，1ms 粒度；skynet 的 `sleep` 是 10ms 粒度，所以 lag 里有 1–10ms 的定时器噪声。内核本身 Elixir 是 2.5–5.1ms/帧，skynet 是 0.16ms/帧。
- **1000 房是分界**：Elixir 每个 `Task` 都要在 4 个 scheduler 上抢执行权，`compute` 的墙钟被调度/进程 GC 拉到 42.5ms，94% 的 tick 超 50ms，max 1.56s；skynet 的 compute 仍是 96µs，输在 coroutine 排队（4 worker p99 82ms，8 worker 32ms）。
- Elixir 的 `compute_*` 在过载时是**墙钟**（包含被抢占的时间），不是纯 CPU；它的 `cpu_seconds` 119.5s 才是真实 CPU，约为 skynet 的 1.8 倍、Go 的 32 倍。
- Go 的 31.9MB 里约 9.6MB 是 600k×2 个 int64 的样本数组（lag/compute 每房每 tick 各一条），不是内核数据；100 房时是 4.3MB。早先表里 1000 房的 5MB 是误把 100 房的数抄过去，已用同机重跑更正。
- 两边都没有在 4 vCPU 上守住 1000 房/40 人；能守住的是 Go。这条对比的价值是：**同样是「一房一个执行单元」的 actor/process 模型，Lua coroutine 的内核 compute p99 比 BEAM process 低约 32 倍（100 房），1000 房时 p99 差 12 倍。**

### Elixir 内存：live 与 RSS

`--live-probe` 会在每房 tick 跑完后对该房进程做一次 fullsweep GC，再读 `Process.info(self(), :memory)` 并求和。探针的 GC 会和 tick 抢 scheduler，所以这一轮只看内存，不看 lag。

| rooms | live_room_bytes | RSS（正常跑） | RSS/live |
|---|---|---|---|
| 1 | 0.06MB | 64MB | ~1000× |
| 10 | 0.62MB | 71MB | 114× |
| 50 | 3.09MB | 85MB | 27× |
| 100 | 6.52MB | 117MB | 18× |
| 1000 | 66.4MB | 531MB | 8× |

- `live_room_bytes` 是 GC 后所有房进程 heap+stack 之和，不含共享代码、binary、ETS、样本数组和分配器空闲页；正常跑与探针跑的 RSS 都在 520–540MB。
- 1000 房时房间状态只有 66MB（约 66KB/房）。531MB 里约 465MB 不在房进程里：600k×2 个样本的 list cell（约 19MB）、BEAM code/binary，以及 4 个 scheduler 的 allocator 保留页。
- 所以 531MB 要分两层看：live 66MB 和 skynet 扣掉 14MB 基线后的 132MB 是同一量级（skynet 那份含 1000 个 Lua VM 的固定开销）；RSS 差距主要是运行时保留，不是数据膨胀。
- 这也解释了 `memory_total` 143MB 为什么仍大于 live 66MB：ERTS 把分配器里的 free block 也算进 total。

## 实现说明

- `sim.lua`：内核（RNG、Room、arena/free 数组、naive 表分配），纯 Lua，无 skynet 依赖，可单独 `lua` 跑。
- `room.lua`：一个房间 service，收 `go` 后 `skynet.fork` 出 tick 循环，结束后把 hash/延迟送回 main。
- `main.lua`：解析参数、起全部房间、对齐同一个 `start_ns`、收集结果、算分位、打 JSON、退出。
- `arena`：弹道/buff/event/snapshot 用预分配数组 + 原地压缩，不产生短命表。
- `naive`：每次 spawn 建 Lua table，snapshot 每帧新建数组，交给 Lua GC。
- Lua 的 `%` 是 floor-mod，不能直接当无符号余数；`u64mod()` 先拆高低 32 位再加权取模（详见 `NOTES.md`）。

## 已知限制

- `rand` 的 64 位语义依赖 Lua 5.5 整数；换 Lua 5.4 也能跑，换 LuaJIT 不行。
- tick 间隔受 skynet 10ms 定时器限制，lag 不能和 µs 级 sleep 的语言逐项对比；看 compute 和 missed 比例更公平。
- `alloc_bytes` / `alloc_objects` 未统计，固定 0；`rss_peak_bytes` 实际是结束时的进程 RSS，不是峰值。
- `naive` 的对象形状是 Lua table，与 Go 的 struct slice 不同，只能比「分配/复用」这条路径的相对差异，不能当同构分配器。
- 1000 房默认 4 worker 不达标；这是 Lua 解释器的吞吐上限，不是 skynet 调度器的锅（8 worker 已把超预算压到 0.2%）。
