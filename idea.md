可以做，而且这个测试如果设计得好，会比普通的“循环分配 1 亿个对象”有意义得多。

先修正测试目标：严格来说不是 “Rust / Go / Zig / Elixir 四种 GC 对比”。Go 有 tracing GC；Elixir 跑在 BEAM 上，使用按 Erlang process 独立的分代 copying GC；Rust 和 Zig 默认走显式生命周期/allocator，不是 tracing GC。Rust 的 `Box` 等对象离开生命周期后释放，Zig 更是显式选择和传递 allocator。([Go][1])

所以我会把项目命名成类似：

`battle-runtime-benchmark`

测的是：

> 同一个游戏战斗服 workload 下，不同语言/runtime 的内存管理方式对 tick latency、tail latency、CPU、内存、吞吐量的影响。

### 1. 先定义一个统一的“战斗服”

不要一上来写网络服务器。第一阶段做完全 deterministic 的 battle simulator。

例如固定成：

```text
Tick rate:          20 Hz
Tick budget:        50 ms

Room:
  players:          40
  NPC:              100
  projectiles:      0~500
  buffs:            0~1000

每玩家:
  movement:         20 次/s
  skill input:      2 次/s
  target change:    0.2 次/s

每 Tick:
  位置更新
  技能冷却
  buff 更新
  projectile 更新
  damage 计算
  death/spawn
  AOI 查询
  创建网络 snapshot

snapshot:
  10 Hz
```

然后并发逐渐增加：

```text
10 rooms
50 rooms
100 rooms
500 rooms
1000 rooms
```

我尤其建议一个 room 就是一个独立执行单元：

```text
Go      -> 1 goroutine / room
Elixir  -> 1 BEAM process / room
Rust    -> 1 task / room
Zig     -> 1 worker/job / room
```

这样 Elixir 的模型也比较合理，因为 BEAM 的 GC 本来就是 per-process 的：每个 Erlang process 有自己的 heap，使用分代 copying collector，而不是整个 VM 一个大 heap 一起收。([Erlang.org][2])

这会产生一个非常值得观察的结果：Go 的 GC 行为和 Elixir 的 GC 行为不能简单地只比较“最大 pause”，因为两者的 pause 影响范围不同。

### 2. 故意设计三种生命周期对象

这是整个实验最关键的部分。

不要只是随机 malloc。

设计：

```text
Long lived
玩家
NPC
技能配置
地图
Room state

生命周期：几十秒 ~ 整场战斗
```

```text
Medium lived
buff
projectile
DOT/HOT
仇恨对象
临时技能状态

生命周期：0.5 ~ 30 秒
```

```text
Short lived
DamageEvent
CollisionResult
TargetList
AOI Result
Packet
Snapshot
临时 Vec/List/Map

生命周期：1 Tick 或更短
```

比如故意让每个 tick：

```text
40 players
    ↓
产生 200 DamageEvent
产生 100 TargetList
产生 300 PositionUpdate
产生 40 SnapshotBuffer
产生 50 Projectile
```

最终做成一个可调参数：

```text
alloc_rate = low
alloc_rate = medium
alloc_rate = high
alloc_rate = insane
```

这样你才能画出：

```text
allocation rate
        ↓
     100 MB/s
     500 MB/s
       1 GB/s
       5 GB/s
        ↓
p99 tick latency
```

这张图实际上会非常有价值。

### 3. 不要让四个实现自己随机

建立统一 replay 文件，例如：

```text
seed = 123456

tick 1:
player 12 move 1.2 3.4
player 18 cast skill 7 target 20

tick 2:
player 5 move ...
player 12 cast ...

...
```

最好甚至不用存整个文件，统一 PRNG 算法 + seed 也可以。

每个实现最终产生：

```text
tick=10000
world_hash=8d73a...
damage_total=18723491
alive_players=31
```

四个版本必须 hash 一样。

否则会出现：

```text
Go 实际计算了 1000 万次 collision
Rust 实际算了 700 万次
```

最后 benchmark 完全没有意义。

### 4. 第一阶段不要加 JSON / Protobuf / DB

先做：

```text
replay
   ↓
battle engine
   ↓
world checksum
```

不联网、不写日志、不访问 Redis、不访问 DB。

测纯粹：

```text
CPU
allocation
memory management
scheduler
GC
tick jitter
```

第二阶段才变成：

```text
Load Generator
      │
      ▼
 UDP/TCP
      │
 Battle Server
      │
 serialization
      │
      ▼
 response
```

这样你最终可以区分：

```text
battle core latency

vs

real server latency
```

### 5. 重点不是平均 latency，而是尾延迟

最重要的输出建议至少有：

```text
tick latency

p50
p95
p99
p99.9
p99.99
max
```

以及：

```text
missed tick %

> 50 ms
> 100 ms
> 200 ms
```

假如 20Hz 战斗服：

```text
tick budget = 50ms
```

一个结果可能会变成：

```text
                 p50     p99    p99.9    max    >50ms
Rust             3.1     4.8      6.1     12      0
Zig              2.9     4.5      5.8     10      0
Go               3.5     6.2     12.1     31      0
Elixir           5.5     9.8     17.5     42      0
```

这只是示意，不是预期结果。

游戏服务器真正关心的是：

> 有没有偶发的超长 tick。

而不是“平均 Tick 是 3ms 还是 4ms”。

### 6. 同时记录 allocation 和 GC

公共指标：

```text
CPU %
RSS
peak RSS
alloc bytes/sec
alloc objects/sec

tick latency
event latency
rooms/core
players/core

context switches
```

Go 再记录：

```text
GC cycles
GC CPU
live heap
heap goal
GC pause histogram
```

Go 官方 `runtime/metrics` 已经提供 `/gc/heap/live:bytes`、heap object 数据以及 GC pause histogram；也可以用 `runtime.ReadMemStats` 和 `GODEBUG=gctrace=1`。([Go][3])

Elixir/BEAM 记录：

```text
GC count
words reclaimed

per-room:
heap_size
total_heap_size
memory
message_queue_len
garbage_collection_info
```

ERTS 可以直接通过 `statistics(garbage_collection)` 和 `process_info(..., garbage_collection_info)` 获取这些信息。([Erlang.org][4])

所以最终你最好能画：

```text
Tick latency
│
│                 ▲ 32 ms
│                 │
│       ▲         │
│       │         │
└──────────────────────── time
        GC        GC
```

而不是仅仅：

```text
Go GC pause average = 0.2 ms
```

后者对游戏服帮助有限。

### 7. Go 我会专门跑这几组

首先：

```bash
GOGC=50
GOGC=100
GOGC=200
```

再增加不同 `GOMEMLIMIT`。

Go 官方 GC guide 明确说明了 `GOGC` 的 CPU/内存 trade-off，并支持通过 `GOMEMLIMIT` 给 runtime 设置 soft memory limit。([Go][1])

所以可以做一张非常有价值的二维图：

```text
            RSS       p99       GC CPU
GOGC=50
GOGC=100
GOGC=200
```

通常这比简单问“Go GC 快不快”有意义得多。

还可以做一个特殊实验：

```bash
GOGC=off
```

Go 官方支持关闭 GC。([Go][1])

但只跑很短的固定 workload，例如：

```text
30 秒 / 固定 10000 tick
```

因为内存会持续增长。

对比：

```text
Go GC on  -> p99 / CPU
Go GC off -> p99 / CPU
```

可以作为估算 GC tax 的实验。

但不能把这个差值严格解释成“纯 GC 开销”，因为 heap 大小、cache locality 等也跟着改变了。

### 8. Elixir 要做一个很有意思的实验

因为 BEAM 是 process-local GC，所以测试：

```text
1 room / process

10 rooms
100 rooms
1000 rooms
5000 rooms
```

观察：

```text
单个 room GC
     ↓
这个 room tick 抖动

vs

其他 room tick 是否仍正常
```

这其实比单纯比较 Go pause 更能展示 BEAM 的设计特点。BEAM 每个 process 都有自己的 heap 和 GC。([Erlang.org][2])

然后测试：

```text
default

min_heap_size ↑

fullsweep_after:
默认
更低
更高
```

ERTS 暴露了 `min_heap_size` 和 `fullsweep_after` 等 GC 参数；`fullsweep_after` 控制进行多少次 generational collections 后强制 full sweep。([Erlang.org][4])

千万不要一开始就调。

应该：

```text
Elixir-default
Elixir-tuned
```

分别出成绩。

不然对其他语言不公平。

### 9. Rust / Zig 也一定要有两个版本

否则比较会对 Go/Elixir 很不公平。

第一版：

```text
naive allocation
```

该 new/allocate 就 allocate。

例如：

```text
DamageEvent
Vec<Target>
Projectile
Snapshot
```

频繁创建销毁。

第二版：

```text
arena / object pool
```

例如一个 tick：

```text
tick_arena.reset()

处理战斗
  DamageEvent
  Collision
  QueryResult
  SnapshotTemp
全部从 arena 分配

tick 完
一次释放/reset
```

然后你就会得到非常有趣的四组：

```text
Rust naive
Rust arena

Zig naive
Zig arena

Go default
Go optimized allocation

Elixir default
Elixir optimized allocation
```

Zig 本身就把 allocator 作为显式设计的一部分，官方文档提供了 `ArenaAllocator`、`FixedBufferAllocator` 和通用 allocator 的选择建议；Zig 0.16 的 ReleaseFast 场景官方还明确列出了 `std.heap.smp_allocator` 作为通用选择。([Zig编程语言][5])

Rust 则可以通过 ownership + `Vec`/`Box` 等做普通 heap 生命周期版本，再自己实现 arena/pool 实验。`Box` 的 heap 对象会由 ownership 生命周期负责释放。([Rust 文档][6])

### 10. 我会建立这套 benchmark matrix

最终不是一次 benchmark，而是：

```text
                   alloc pressure
               low    mid    high

Rust naive
Rust arena

Zig naive
Zig arena

Go GOGC=50
Go GOGC=100
Go GOGC=200

Elixir default
Elixir tuned
```

每组再测试：

```text
10 rooms
100 rooms
500 rooms
1000 rooms
```

所以最后可以画三个最关键的图。

第一张：

```text
Rooms
  ↑
1000 |                 X
 500 |          X
 100 |    X
     +──────────────────→ p99 tick
       5  10  20  50ms
```

第二张：

```text
Allocation MB/s
        ↓
p99 tick latency
```

第三张：

```text
RSS
 ↓

 latency / memory tradeoff
```

第三张尤其重要。

因为最后很可能不是：

> Rust 比 Go 快 X%。

而会变成：

> 为了保证 p99.9 < 20ms，Go 需要 3.2GB，Rust 需要 1.8GB，Elixir 需要 4GB；但是 BEAM 在单房间 GC 时对其他房间的隔离情况不同。

这种结论才对战斗服务器选型有价值。

### 11. 推荐项目结构

我会直接这么建：

```text
battle-bench/
│
├── spec/
│   ├── battle.md
│   ├── event-format.md
│   └── workload.toml
│
├── workloads/
│   ├── low.toml
│   ├── medium.toml
│   ├── high.toml
│   └── burst.toml
│
├── rust/
│   └── ...
│
├── go/
│   └── ...
│
├── zig/
│   └── ...
│
├── elixir/
│   └── ...
│
├── loadgen/
│
├── scripts/
│   ├── run_all.sh
│   └── collect.sh
│
└── results/
    └── *.json
```

每个服务器统一接受：

```bash
./server \
  --rooms 100 \
  --players 40 \
  --ticks 12000 \
  --seed 1234 \
  --workload high
```

统一输出：

```json
{
  "ticks": 12000,
  "world_hash": "...",
  "tick_p50_us": 3200,
  "tick_p99_us": 7100,
  "tick_p999_us": 15300,
  "tick_max_us": 28800,
  "rss_peak": 891289600,
  "cpu_seconds": 183.2,
  "alloc_bytes": 38123781273
}
```

语言自己的 GC 数据再放：

```json
"runtime": {
}
```

里面。

最开始我建议只实现一个非常小的版本：**40 玩家/房间、20Hz、Damage + Buff + Projectile + Snapshot 四种会制造不同生命周期对象的系统，然后先写 Go 和 Rust 两版。** 等 workload 和测量方法稳定后再加 Zig 和 Elixir。这样可以避免最后写了四套服务器，却发现 benchmark 模型本身不可信。

另外，当前稳定 Zig 是 0.16.0；这种跨语言 benchmark 最好把编译器、runtime、build flags 全部 pin 进结果文件，避免半年后重跑已经不是同一个环境。([Zig编程语言][7])

[1]: https://go.dev/doc/gc-guide?utm_source=chatgpt.com "A Guide to the Go Garbage Collector"
[2]: https://www.erlang.org/doc/apps/erts/garbagecollection.html?utm_source=chatgpt.com "Erlang Garbage Collector — OTP 29.0.3 (erts 17.0.3)"
[3]: https://go.dev/doc/diagnostics?utm_source=chatgpt.com "Diagnostics - The Go Programming Language"
[4]: https://www.erlang.org/doc/apps/erts/erlang.html?utm_source=chatgpt.com "erlang — OTP 29.0.3 (erts 17.0.3)"
[5]: https://ziglang.org/documentation/0.16.0/?utm_source=chatgpt.com "Documentation - The Zig Programming Language"
[6]: https://doc.rust-lang.org/std/boxed/struct.Box.html?utm_source=chatgpt.com "Box in std"
[7]: https://ziglang.org/download/?utm_source=chatgpt.com "Download ⚡ Zig Programming Language"
