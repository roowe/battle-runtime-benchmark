# Elixir BEAM 封存 · 2026-08-13

调度：1 房间 1 个 BEAM process（`Task.async`）。naive/arena 同一套内核；BEAM 没有真正的 arena，差别只是列表重建方式。
主指标 deadline lag。seed=1234。world_hash 与 Go/Rust/Zig 对齐。

## 短对比 · matrix_elixir.jsonl

Mac Mini M4 10 核 · Elixir 1.20.3 / OTP 28.4 · 2 分钟/格 · 12 格
12 格 hash 全部与同格 Go/Rust 对齐。

## 长对比 · long_elixir.jsonl

本机 12 核 · Elixir 1.20.2 / OTP 29 · 复用 · 1000 房高压 · 30 分钟
hash=109d9249dcab5cce（与 Go/Rust/Zig 长跑相同）
lag p99 14.9ms · max 131ms · 超 50ms 2257 次 · 超 100ms 52 次
计算 p99 10.9ms（Go/Rust/Zig 均为 15µs）
RSS 2140MB · CPU 4547s（`:erlang.statistics(:runtime)`，不是 getrusage）
