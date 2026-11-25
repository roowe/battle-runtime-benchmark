#!/bin/sh
set -e
cd "$(dirname "$0")"
ROOMS=${ROOMS:-"1 10 50 100"}
ALLOCS=${ALLOCS:-"arena naive"}
WORKLOAD=${WORKLOAD:-medium}
TICKS=${TICKS:-600}
SEED=${SEED:-1234}
PLAYERS=${PLAYERS:-40}
OUT=${OUT:-results/matrix_skynet.jsonl}
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
for rooms in $ROOMS; do
  for alloc in $ALLOCS; do
    echo "== rooms=$rooms alloc=$alloc workload=$WORKLOAD ticks=$TICKS" >&2
    tmp=$(mktemp)
    ./run.sh "rooms=$rooms;players=$PLAYERS;ticks=$TICKS;seed=$SEED;workload=$WORKLOAD;alloc=$alloc" > "$tmp" 2>/dev/null
    python3 - "$tmp" "$OUT" <<'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
text = open(src).read()
i = text.find('{\n  "lang"')
data = json.loads(text[i:text.rfind('}') + 1])
with open(out, 'a') as f:
    f.write(json.dumps(data, separators=(',', ':')) + '\n')
PY
    rm -f "$tmp"
  done
done
echo "wrote $OUT" >&2
