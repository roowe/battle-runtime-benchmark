# Java 虚拟线程封存 · 2026-08-13

调度：1 房间 1 条虚拟线程（OpenJDK 25）。naive 每次 `new`；arena 对象池复用弹道/buff/事件。
主指标 deadline lag。seed=1234。world_hash 与 Go/Rust/Zig/Elixir 对齐。
百分位下标用 `long` 运算（第一轮 `int` 溢出，p99 作废后重跑）。

## 短对比 · matrix_java.jsonl

Mac Mini M4 10 核 · OpenJDK 25.0.4 · 2 分钟/格 · 12 格
12 格 hash 全部与同格 Go 对齐。

## 长对比 · long_java.jsonl

本机 12 核 · OpenJDK 25.0.4 · 复用 · 1000 房高压 · 30 分钟
hash=109d9249dcab5cce
lag p99 11.1ms · max 67ms · 超 50ms 1052 次 · 超 100ms 0 次
计算 p99 62µs（Go/Rust/Zig 15µs，Elixir 10.9ms）
RSS 1937MB · CPU 577s · GC 43 次 / 累计 85ms
