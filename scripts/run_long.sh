#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$root/results"
mkdir -p "$out_dir"
out="$out_dir/long.jsonl"
: >"$out"

go build -C "$root/go" -o battle .
cargo build --quiet --release --manifest-path "$root/rust/Cargo.toml"

seed=1234
# 20Hz × 30 minutes
ticks=36000

run() {
  local lang="$1" alloc="$2" rooms="$3" workload="$4"
  local bin
  if [[ "$lang" == "go" ]]; then
    bin="$root/go/battle"
  else
    bin="$root/rust/target/release/battle-bench"
  fi
  "$bin" --seed "$seed" --ticks "$ticks" --rooms "$rooms" --workload "$workload" --alloc "$alloc" \
    | python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout); print()'
}

while read -r lang alloc rooms workload; do
  printf '%s run %s %s rooms=%s %s ticks=%s\n' "$(date '+%H:%M:%S')" "$lang" "$alloc" "$rooms" "$workload" "$ticks" >&2
  run "$lang" "$alloc" "$rooms" "$workload" >>"$out"
  printf '%s done %s %s\n' "$(date '+%H:%M:%S')" "$lang" "$alloc" >&2
done <<'CASES'
go arena 1000 high
rust arena 1000 high
CASES

printf 'wrote %s\n' "$out" >&2
