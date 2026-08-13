#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
rooms="${1:-100}"
ticks="${2:-200}"
workload="${3:-high}"
alloc="${4:-arena}"
seed="${5:-1234}"

(cd "$root/elixir" && MIX_ENV=prod mix escript.build >&2)

uv run python - "$root" "$rooms" "$ticks" "$workload" "$alloc" "$seed" <<'PY'
import json
import subprocess
import sys

root, rooms, ticks, workload, alloc, seed = sys.argv[1:]
binary = f"{root}/elixir/battle_bench"
stores = ("tuple", "list", "map")
results = {}

for store in stores:
    command = [
        binary,
        "--rooms", rooms,
        "--ticks", ticks,
        "--workload", workload,
        "--alloc", alloc,
        "--seed", seed,
        "--player-store", store,
    ]
    results[store] = json.loads(subprocess.check_output(command))

signatures = {
    store: (result["world_hash"], result["damage_total"], result["alive_players"])
    for store, result in results.items()
}

if len(set(signatures.values())) != 1:
    for store, signature in signatures.items():
        print(f"{store}: {signature}", file=sys.stderr)
    raise SystemExit("player stores produced different world states")

print(
    f"rooms={rooms} ticks={ticks} workload={workload} alloc={alloc} seed={seed} "
    f"hash={next(iter(signatures.values()))[0]}"
)
print(
    f"{'store':<8} {'compute p50':>12} {'compute p99':>12} "
    f"{'lag p99':>10} {'lag max':>10} {'>50ms':>8} {'GC':>10} {'RSS MB':>10} {'CPU s':>10}"
)

for store in stores:
    result = results[store]
    runtime = result["runtime"]
    print(
        f"{store:<8} "
        f"{result['compute_p50_us'] / 1000:>11.3f}ms "
        f"{result['compute_p99_us'] / 1000:>11.3f}ms "
        f"{result['tick_p99_us'] / 1000:>9.3f}ms "
        f"{result['tick_max_us'] / 1000:>9.3f}ms "
        f"{result['missed_50ms']:>8} "
        f"{runtime['gc_count']:>10} "
        f"{result['rss_peak_bytes'] / 1_000_000:>10.1f} "
        f"{result['cpu_seconds']:>10.3f}"
    )
PY
