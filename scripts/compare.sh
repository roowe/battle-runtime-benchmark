#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
seed="${1:-1234}"
ticks="${2:-200}"
workload="${3:-medium}"

go build -C "$root/go" -o battle .
cargo build --quiet --release --manifest-path "$root/rust/Cargo.toml"

run_one() {
  local lang="$1" alloc="$2"
  if [[ "$lang" == "go" ]]; then
    "$root/go/battle" --seed "$seed" --ticks "$ticks" --workload "$workload" --alloc "$alloc"
  else
    "$root/rust/target/release/battle-bench" --seed "$seed" --ticks "$ticks" --workload "$workload" --alloc "$alloc"
  fi
}

python3 - "$seed" "$ticks" "$workload" "$(run_one go naive)" "$(run_one go arena)" "$(run_one rust naive)" "$(run_one rust arena)" <<'PY'
import json, sys

seed, ticks, workload = sys.argv[1], sys.argv[2], sys.argv[3]
runs = {
    "go naive": json.loads(sys.argv[4]),
    "go arena": json.loads(sys.argv[5]),
    "rust naive": json.loads(sys.argv[6]),
    "rust arena": json.loads(sys.argv[7]),
}
keys = ("world_hash", "damage_total", "alive_players")
ref = None
ok = True
for name, d in runs.items():
    sig = tuple(d[k] for k in keys)
    print(f"{name:<12} hash={d['world_hash']} damage={d['damage_total']} alive={d['alive_players']}")
    if ref is None:
        ref = sig
    elif sig != ref:
        print(f"MISMATCH: {name} {sig} != {ref}")
        ok = False
if not ok:
    sys.exit(1)
print(f"OK: all four match  seed={seed} ticks={ticks} workload={workload}")
PY
