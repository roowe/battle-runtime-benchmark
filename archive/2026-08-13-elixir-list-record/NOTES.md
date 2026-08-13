# Elixir list record 长测封存 · 2026-08-13

本归档记录 `BattleBench.SimList` 的 30 分钟长测。运行时实体集合 `players`、`projectiles`、`buffs`、`damage_events` 均为 Elixir list，元素均为 Erlang record。`alloc=arena` 只为兼容统一命令行接口，不会改变 `SimList` 的实现。

## 测试配置

- 机器：本机 12 scheduler，aarch64 / macOS
- 工具链：Elixir 1.20.2 / OTP 29
- 调度：1 房间 1 个 `Task.async` process
- 负载：1000 rooms × 40 players × high
- 时长：36000 tick，20Hz，真实约 30 分钟
- seed：1234
- player store：list record
- 原始结果：`long_elixir_list_record.jsonl`

执行命令：

```bash
./elixir/battle_bench \
  --seed 1234 \
  --ticks 36000 \
  --rooms 1000 \
  --players 40 \
  --workload high \
  --alloc arena \
  --player-store list
```

## 正确性

新版与原版 tuple 长测状态完全一致：

- world hash：`109d9249dcab5cce`
- damage total：`39546286`
- alive players：`9708`

## 与原版 tuple 对比

原版数据来自 `../2026-08-13-elixir-beam/long_elixir.jsonl`，测试规格、Elixir/OTP 版本和 scheduler 数一致。

| 指标 | 原版 tuple | list record | 变化 |
|---|---:|---:|---:|
| compute p50 | 4.729ms | 2.948ms | -37.7% |
| compute p99 | 10.887ms | 8.569ms | -21.3% |
| compute p999 | 15.454ms | 12.912ms | -16.4% |
| compute max | 119.067ms | 143.638ms | +20.6% |
| lag p50 | 8.969ms | 7.707ms | -14.1% |
| lag p99 | 14.939ms | 12.809ms | -14.3% |
| lag p999 | 24.435ms | 25.120ms | +2.8% |
| lag max | 131.187ms | 169.940ms | +29.5% |
| 超过 50ms | 2257 | 4659 | +106.4% |
| 超过 100ms | 52 | 1306 | +2411.5% |
| GC 次数 | 22523504 | 17473976 | -22.4% |
| GC 回收字节估算 | 3.900TB | 3.124TB | -19.9% |
| `:erlang.statistics(:runtime)` | 4547.188s | 3476.254s | -23.6% |
| 结束时 RSS 快照 | 2.244GB | 5.973GB | +166.1% |

结论：list record 明显降低常态计算时间、runtime 和垃圾回收量，但本轮极端尾延迟更差。单次长测不足以证明尾延迟恶化由 list record 本身造成。

## 实体 term 大小

使用 `:erts_debug.flat_size/1 × wordsize` 测量单房间第 600 tick 的相同确定性状态：

| 数据 | 原版 tuple/map entity | list/record entity | 变化 |
|---|---:|---:|---:|
| room | 16984B | 9536B | -43.9% |
| players | 6088B | 3520B | -42.2% |
| projectiles（52 个） | 9984B | 5408B | -45.8% |
| buffs（9 个） | 720B | 432B | -40.0% |

战斗实体的存活数据实际更小；5.973GB RSS 不能解释为 list record 房间本身占用更多内存。

## 指标口径与已知偏差

1. `rss_peak_bytes` 名称不准确。实现只在汇总、排序完成后通过 `ps` 读取一次 RSS，因此它是结束时快照，不是真正的全程峰值。
2. `alloc_bytes` 不是实际分配字节。它来自 `:erlang.statistics(:garbage_collection)` 的 `WordsReclaimed × wordsize`，应理解为 GC 回收字节估算。
3. `alloc_objects` 实际等于 GC 次数，不是对象分配数量。
4. 每个房间保存 warmup 后所有 lag/compute 样本。本次共保存 `1000 × 35980 × 2 = 71960000` 个 list 元素；Task 返回时还会发生跨进程消息复制，主进程随后执行两次 `Enum.flat_map/2` 和两次全量排序。RSS 因此主要受到统计器临时内存和 ERTS allocator 高水位影响。
5. 1000 个房间共享同一个 start 和 deadline。一次全局停顿可能同时形成接近 1000 个超时样本，因此 `missed_100ms=1306` 不等于 1306 次彼此独立的停顿。
6. 第一次长测在受限沙箱内完成仿真后，因为 `ps` 无法读取 BEAM PID 而在 RSS 汇总阶段退出；归档 JSON 来自随后在正常权限环境中的完整重跑。

如需判断尾延迟是否由数据结构造成，应改用在线直方图或分桶统计，只额外保留少量最慢样本的 `{room_id, tick, lag, compute}`，并至少重复三轮。
