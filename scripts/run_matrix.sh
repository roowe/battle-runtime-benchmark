#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$root/results"
mkdir -p "$out_dir"
only="${ONLY:-}"
case "$only" in
  zig) out="$out_dir/matrix_zig.jsonl" ;;
  elixir) out="$out_dir/matrix_elixir.jsonl" ;;
  *) out="$out_dir/matrix.jsonl" ;;
esac
: >"$out"

if [[ -z "$only" || "$only" == "go" ]]; then
  go build -C "$root/go" -o battle .
fi
if [[ -z "$only" || "$only" == "rust" ]]; then
  cargo build --quiet --release --manifest-path "$root/rust/Cargo.toml"
fi
if [[ -z "$only" || "$only" == "zig" ]]; then
  if [[ "${ZIG_SKIP_BUILD:-}" != "1" ]]; then
    zig build --build-file "$root/zig/build.zig" -Doptimize=ReleaseFast --prefix "$root/zig/zig-out"
  fi
fi
if [[ -z "$only" || "$only" == "elixir" ]]; then
  (cd "$root/elixir" && MIX_ENV=prod mix escript.build >&2)
fi

seed=1234
# 20Hz × 2 minutes
ticks=2400

run() {
  local lang="$1" alloc="$2" rooms="$3" workload="$4"
  local bin
  case "$lang" in
    go) bin="$root/go/battle" ;;
    rust) bin="$root/rust/target/release/battle-bench" ;;
    zig) bin="$root/zig/zig-out/bin/battle-bench" ;;
    elixir) bin="$root/elixir/battle_bench" ;;
    *) printf 'unknown lang %s\n' "$lang" >&2; exit 1 ;;
  esac
  "$bin" --seed "$seed" --ticks "$ticks" --rooms "$rooms" --workload "$workload" --alloc "$alloc" \
    | python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout); print()'
}

while read -r lang alloc rooms workload; do
  if [[ -n "$only" && "$lang" != "$only" ]]; then
    continue
  fi
  printf '%s run %s %s rooms=%s %s ticks=%s\n' "$(date '+%H:%M:%S')" "$lang" "$alloc" "$rooms" "$workload" "$ticks" >&2
  run "$lang" "$alloc" "$rooms" "$workload" >>"$out"
  printf '%s done %s %s\n' "$(date '+%H:%M:%S')" "$lang" "$alloc" >&2
done <<'CASES'
go naive 100 medium
go arena 100 medium
rust naive 100 medium
rust arena 100 medium
zig naive 100 medium
zig arena 100 medium
go naive 100 high
go arena 100 high
rust naive 100 high
rust arena 100 high
zig naive 100 high
zig arena 100 high
go naive 500 medium
go arena 500 medium
rust naive 500 medium
rust arena 500 medium
zig naive 500 medium
zig arena 500 medium
go naive 500 high
go arena 500 high
rust naive 500 high
rust arena 500 high
zig naive 500 high
zig arena 500 high
go naive 1000 medium
go arena 1000 medium
rust naive 1000 medium
rust arena 1000 medium
zig naive 1000 medium
zig arena 1000 medium
go naive 1000 high
go arena 1000 high
rust naive 1000 high
rust arena 1000 high
zig naive 1000 high
zig arena 1000 high
elixir naive 100 medium
elixir arena 100 medium
elixir naive 100 high
elixir arena 100 high
elixir naive 500 medium
elixir arena 500 medium
elixir naive 500 high
elixir arena 500 high
elixir naive 1000 medium
elixir arena 1000 medium
elixir naive 1000 high
elixir arena 1000 high
CASES

printf 'wrote %s\n' "$out" >&2
