# Zig skynet-worker-pool 封存 · 2026-08-13

调度：N 个 OS worker + 全局就绪队列 + 1ms timer（对标 skynet，不是绿线程）。
主指标 deadline lag。seed=1234。与 Go/Rust 同格 world_hash 对齐。

## 短对比 · matrix_zig.jsonl
Mac Mini M4 10 核 · 2 分钟/格 · 12 格（朴素/复用 × 100/500/1000 × 中等/高压）

## 长对比 · long_zig.jsonl
本机 12 核 · 复用 · 1000 房高压 · 30 分钟
hash=109d9249dcab5cce（与 Go/Rust 长跑相同）
lag p99 4.6ms · max 42ms · 超 50ms 0 次

