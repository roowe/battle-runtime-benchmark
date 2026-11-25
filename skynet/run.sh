#!/bin/sh
set -e
SKYNET_ROOT=${SKYNET_ROOT:-$HOME/skynet}
DIR=$(cd "$(dirname "$0")" && pwd)
CFG=$(mktemp /tmp/skynet-bench.XXXXXX)
ARGS="$*"
cat > "$CFG" <<CONF
thread = ${SKYNET_THREAD:-4}
logger = nil
harbor = 0
start = "main"
bootstrap = "snlua bootstrap"
lualoader = "$SKYNET_ROOT/lualib/loader.lua"
cpath = "$SKYNET_ROOT/cservice/?.so"
luaservice = "$SKYNET_ROOT/service/?.lua;$DIR/?.lua"
lua_path = "$SKYNET_ROOT/lualib/?.lua;$DIR/?.lua"
lua_cpath = "$SKYNET_ROOT/luaclib/?.so"
bench_args = "$ARGS"
CONF
exec "$SKYNET_ROOT/skynet" "$CFG"
