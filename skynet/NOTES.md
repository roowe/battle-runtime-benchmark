# Skynet / Lua 实现笔记

## 版本与机器

- 豆包云主机：Linux x64，4 vCPU，Ubuntu 22.04，8GB
- skynet `a2c00da`（2026-11-24），`make -j4 linux`
- 自带 Lua 5.5（`_VERSION == "Lua 5.5"`），64 位整数
- Go 对照：同机同参数，`GOMAXPROCS=4`
- seed 1234，40 人/房

## 构建与启动

```bash
git clone --depth 1 https://github.com/cloudwu/skynet.git "$HOME/skynet"
cd "$HOME/skynet" && make -j4 linux
```

配置文件里 **必须有 `lualoader`**：

```conf
lualoader = "$SKYNET_ROOT/lualib/loader.lua"
```

少了它，`snlua bootstrap` 会静默停在 LAUNCH 之后，不报错也不退出——查了很久。`run.sh` 已经把这段写进生成的临时配置。

## service 参数的两个坑

1. `skynet.newservice("room", id, cfg)` 的参数在 launcher 里是 `table.concat(..., " ")`，loader 再按空白切分后传给 chunk。所以房间脚本必须写 `local room_id, cfg_s = ...`；写成两行 `local room_id = ...` / `local cfg_s = ...` 时，第二个 `...` 取到的还是第一个值（实测拿到的是 `"1"`）。
2. 64 位 hash 不要走 skynet 的 Lua 序列化：直接 `string.format("%016x")` 发字符串，main 里按 16 进制逐位累加回整数，避开浮点/整数子类型边界。

## 计时

- `skynet.hpc()` 是 `clock_gettime(CLOCK_MONOTONIC)` 的 ns 值，用来算 `compute` 和完成时刻。
- skynet 定时器线程每 2.5ms 跑一次，`skynet.now()` 以 1/100s 递增，`skynet.sleep(n)` 只能睡 n 个 centisecond。
- 所以 `sleep(ceil(剩余/10ms))` 的唤醒误差是 0–10ms，lag 的 p50 在 1 房时也有 1.4ms。想让 lag 和 Go 一样只剩 compute，需要 <1ms 的睡眠原语，skynet 没有；不要把这个差当成内核差。
- 主服务在起完所有房间后，取 `hpc()+300ms` 并向上对齐到 10ms 作为共同 `start`；房间先睡到 `start` 再进 tick 0。

## Lua 64 位语义

Lua 5.5 整数是二进制补码 64 位：

- `+`、`-`、`*` 按 2^64 回绕，正好覆盖 splitmix64 和 `mix()`。
- `~` 是 xor；`>>` 是**逻辑右移**（高位补 0），所以 `LShr` 不需要自己写。
- `%` 是 floor-mod：`-5 % 7 == 2`。Go 的 `uint64 % 7` 对 `2^64-5` 得 4，直接用 Lua `%` 会错。`u64mod()` 拆成：

```lua
local hi = x >> 32            -- 逻辑右移，0..2^32-1
local lo = x & 0xFFFFFFFF
return ((hi % d) * (4294967296 % d) + lo) % d
```

`d` 最大 50，中间值 < 2^53，不会丢精度。RNG 取 `%7` 和 `%castMod` 都走它。

## 分配路径

- `arena`：弹道、buff、event、snapshot 都是预分配数字数组，压缩时按顺序前移，不建短命表；snapshot 每帧复用。
- `naive`：每次 spawn 新建 Lua table，event 每帧新建表，snapshot 每帧新建 4 个数组。
- 这和 Go 的 struct slice 不是同构分配：Lua table 有 hash 部分和 GC 头，naive 的绝对成本被放大。表里只能读「复用 vs 不复用」的相对差，不能当分配器横比。

## 同机 Elixir 工具链

仓库 `../elixir` 需要 OTP 27（代码用了 OTP 27 的 `:json` 模块）和 Elixir ~> 1.17，云主机没有现成包，做法：

1. 从清华镜像装 `libssl-dev` / `libncurses-dev` / `m4` / `unzip`（archive.ubuntu.com 不通）。
2. 源码编译 OTP `OTP-27.3.4.20` 到 `/home/user/otp27`：
   `./configure --prefix=/home/user/otp27 --without-javac --without-wx --without-odbc --without-docs && make -j4 && make install`
3. 本轮踩的坑：`debugger` / `observer` / `et` 的 `wx` 模块在 `--without-wx` 下会报 `behaviour wx_object undefined`。解法是在 `lib/SKIP-APPLICATIONS` 写 `debugger observer wx jinterface odbc et`，让顶层 build 跳过这些 app。
4. Elixir 用官方预编译包 `elixir-otp-27.zip`（v1.18.4），解压到 `/home/user/elixir`，`PATH` 同时加 `otp27/bin` 和 `elixir/bin`。
5. `cd elixir && mix escript.build`，产物 `battle_bench`。

Elixir 侧结果（600 tick，medium，arena，4 scheduler，`player_store=tuple`）：

| rooms | lag p50 | lag p99 | compute p50 | compute p99 | CPU | RSS |
|---|---|---|---|---|---|---|
| 1 | 1.56ms | 1.90ms | 245µs | 500µs | 0.18s | 64MB |
| 10 | 1.45ms | 1.69ms | 405µs | 630µs | 1.65s | 71MB |
| 50 | 2.50ms | 3.72ms | 984µs | 2.35ms | 6.74s | 85MB |
| 100 | 4.47ms | 6.73ms | 2.56ms | 5.15ms | 13.0s | 117MB |
| 1000 | 224.7ms | 984.8ms | 42.5ms | 52.5ms | 119.5s | 531MB |

1000 房 94% 的 tick 超 50ms。过载时 Elixir 的 `compute_*` 是被抢占的墙钟，不等于纯 CPU；看 `cpu_seconds`。

内存补充：`--live-probe` 在每个房进程跑完后做 fullsweep GC，读 `Process.info(self(), :memory)` 求和，得到 live_room_bytes（不含共享 code/binary/ETS/样本数组）。1000 房 66.4MB，RSS 531MB；1/10/50/100 房分别是 0.06/0.62/3.09/6.52MB。探针会和 tick 抢 scheduler，带探针的 run 不要用于 lag/compute 对比。

## 结果摘要

8 格矩阵（600 tick，medium，4 worker）全部与 Go hash 对齐，数字见 `README.md` / `archive/2026-11-25-doubao-cloud/`。

1000 房 600 tick arena：

| worker | lag p50 | p99 | p999 | max | 超 50ms | compute p99 | RSS | CPU |
|---|---|---|---|---|---|---|---|---|
| 4 | 15.7ms | 82.4ms | 127.7ms | 146.5ms | 12263 | 253µs | 146MB | 68.4s |
| 8 | 15.4ms | 32.4ms | 64.4ms | 90.9ms | 1177 | 207µs | 156MB | 66.7s |

CPU 约 67s，Go 3.69s（18 倍）；每 tick 1000 房 × ~96µs ≈ 96ms 的单核工作量，4 worker 理论 24ms，实际 p99 被排队和 GC 抬到 82ms。8 worker 把队列摊平，代价是线程多于 4 个 vCPU，仍有 0.2% 越线。

## 复现

```bash
./run.sh "rooms=1000;players=40;ticks=600;seed=1234;workload=medium;alloc=arena"
SKYNET_THREAD=8 ./run.sh "rooms=1000;players=40;ticks=600;seed=1234;workload=medium;alloc=arena"
```

对拍：

```bash
/tmp/battle_go --rooms 1000 --players 40 --ticks 600 --seed 1234 --workload medium --alloc arena
```
