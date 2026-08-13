# Go / Rust deadline-lag 封存 · 2026-08-13

主指标：到期 → 做完（`metric=deadline_lag`，20Hz / 50ms）。
次指标：`tick()` 纯计算。warmup 20 tick 不进延迟统计。

## 短对比 · matrix.jsonl

- 机器：Mac Mini M4，10 核
- 时长：真实 2 分钟 / 格（2400 tick）
- 格子：Go/Rust × 朴素/复用 × 100/500/1000 房 × 中等/高压
- 工具链：Go 1.26.1，Rust 1.94
- 每格四种组合 world_hash 对齐

## 长对比 · long.jsonl

- 机器：本机 12 核，Go 1.26.2
- 时长：真实 30 分钟 / 语言（36000 tick）
- 配置：复用 + 1000 房高压（短跑里两边更好的那套）
- hash 对齐 `109d9249dcab5cce`
- Go lag p99 5.1ms，max 173ms，超 50ms 6000 次（其中 3000 超 100ms）
- Rust lag p99 12.9ms，max 24ms，超 50ms 0 次
- 两边 compute p99 均为 15µs

后续 Zig/Elixir 跑数写 `results/`，不要覆盖本目录。
