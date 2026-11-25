# 2026-11-25 skynet / 豆包云主机

## 机器与工具链

- 豆包云主机：Linux x64，4 vCPU，8GB，Ubuntu 22.04
- skynet `a2c00da`（2026-11-24），`make -j4 linux`，自带 Lua 5.5
- Go 对照：`go1.23.0`，`GOMAXPROCS=4`，同机同参数
- seed 1234，40 人/房，medium
- 默认 4 worker；1000 房另有 8 worker 版本

## 文件

| 文件 | 内容 |
|---|---|
| `matrix_skynet.jsonl` | 8 格：1/10/50/100 房 × arena/naive，600 tick，medium，4 worker |
| `rooms_1000_threads4.json` | 1000 房，600 tick，medium，arena，4 worker |
| `rooms_1000_threads8.json` | 同上，8 worker |
| `matrix_elixir.jsonl` | 同机 Elixir 8 格（1/10/50/100 × arena/naive），600 tick，medium |
| `rooms_1000_elixir.json` | 同机 Elixir 1000 房，600 tick，medium，arena |
| `matrix_elixir_live.jsonl` | Elixir 1/10/50/100 房的内存探针（GC 后进程堆） |
| `rooms_1000_elixir_live.json` | Elixir 1000 房内存探针 |

## 摘要

- 8 格 `world_hash` / `damage_total` / `alive_players` 与同机 Go 全部一致。
- 1–100 房均 0 次超 50ms；100 房 arena lag p99 8.9ms、compute p99 159µs。
- 1000 房 4 worker：lag p99 82.4ms、超 50ms 12263 次（600k tick 的 2%）、compute p99 253µs、RSS 146MB、CPU 68.4s。
- 1000 房 8 worker：lag p99 32.4ms、超 50ms 1177 次（0.2%）、无 >100ms、CPU 66.7s。
- Go 1000 房：lag p50 1.51ms / p99 2.65ms / max 3.19ms、0 次超预算、RSS 31.9MB、CPU 3.83s（`rooms_1000_go.json`）。其中约 9.6MB 是 600k×2 个 int64 的样本数组；100 房 RSS 4.3MB。

## Elixir 对照（同机，OTP 27 + Elixir 1.18.4，4 scheduler）

| rooms | lag p50 | lag p99 | lag max | 超 50ms | compute p50 | compute p99 | CPU | RSS |
|---|---|---|---|---|---|---|---|---|
| 1 | 1.56ms | 1.90ms | 2.6ms | 0 | 245µs | 500µs | 0.18s | 64MB |
| 10 | 1.45ms | 1.69ms | 2.6ms | 0 | 405µs | 630µs | 1.65s | 71MB |
| 50 | 2.50ms | 3.72ms | 5.5ms | 0 | 984µs | 2.35ms | 6.74s | 85MB |
| 100 | 4.47ms | 6.73ms | 16.5ms | 0 | 2.56ms | 5.15ms | 13.0s | 117MB |
| 1000 | 224.7ms | 984.8ms | 1559.3ms | 564776 | 42.5ms | 52.5ms | 119.5s | 531MB |

内存探针（每房跑完后 fullsweep GC 再读进程堆，**该轮 tick 计时不可用**）：

| rooms | live_room_bytes | RSS（正常跑） |
|---|---|---|
| 1 | 0.06MB | 64MB |
| 10 | 0.62MB | 71MB |
| 50 | 3.09MB | 85MB |
| 100 | 6.52MB | 117MB |
| 1000 | 66.4MB | 531MB |

## Go 对照（同机，本目录未入库）

| alloc | rooms | lag p50 | lag p99 | lag max | CPU |
|---|---|---|---|---|---|
| arena | 1 | 0.58ms | 1.07ms | 3.3ms | 0.04s |
| arena | 10 | 0.61ms | 1.13ms | 1.7ms | 0.11s |
| arena | 50 | 0.67ms | 1.18ms | 1.4ms | 0.26s |
| arena | 100 | 0.71ms | 1.82ms | 6.2ms | 0.49s |
| naive | 100 | 0.72ms | 1.40ms | 1.8ms | 0.67s |
| arena | 1000 | 1.52ms | 2.64ms | 3.58ms | 3.69s |
