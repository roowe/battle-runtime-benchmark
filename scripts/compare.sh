#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
seed="${1:-1234}"
ticks="${2:-200}"
workload="${3:-medium}"

go build -C "$root/go" -o battle .
cargo build --quiet --release --manifest-path "$root/rust/Cargo.toml"
zig build --build-file "$root/zig/build.zig" -Doptimize=ReleaseFast --prefix "$root/zig/zig-out"
(cd "$root/elixir" && MIX_ENV=prod mix escript.build >&2)

python3 - "$root" "$seed" "$ticks" "$workload" <<'PY'
import json, subprocess, sys

root, seed, ticks, workload = sys.argv[1:5]
bins = {
    "go naive": [f"{root}/go/battle", "--alloc", "naive"],
    "go arena": [f"{root}/go/battle", "--alloc", "arena"],
    "rust naive": [f"{root}/rust/target/release/battle-bench", "--alloc", "naive"],
    "rust arena": [f"{root}/rust/target/release/battle-bench", "--alloc", "arena"],
    "zig naive": [f"{root}/zig/zig-out/bin/battle-bench", "--alloc", "naive"],
    "zig arena": [f"{root}/zig/zig-out/bin/battle-bench", "--alloc", "arena"],
    "elixir naive": [f"{root}/elixir/battle_bench", "--alloc", "naive"],
    "elixir arena": [f"{root}/elixir/battle_bench", "--alloc", "arena"],
}
keys = ("world_hash", "damage_total", "alive_players")
ref = None
ok = True
for name, bin_cmd in bins.items():
    cmd = bin_cmd + ["--seed", seed, "--ticks", ticks, "--workload", workload]
    d = json.loads(subprocess.check_output(cmd))
    sig = tuple(d[k] for k in keys)
    print(f"{name:<14} hash={d['world_hash']} damage={d['damage_total']} alive={d['alive_players']}")
    if ref is None:
        ref = sig
    elif sig != ref:
        print(f"MISMATCH: {name} {sig} != {ref}")
        ok = False
if not ok:
    sys.exit(1)
print(f"OK: all eight match  seed={seed} ticks={ticks} workload={workload}")
PY
