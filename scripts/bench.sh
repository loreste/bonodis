#!/bin/sh
# Microbench: SET/GET against a local Bonodis (or Redis) on $HOST:$PORT.
# Usage: ./scripts/bench.sh [host] [port] [n]
set -eu
HOST="${1:-127.0.0.1}"
PORT="${2:-6379}"
N="${3:-20000}"
CLI="${BONODIS_CLI:-./bonodis-cli}"
if [ ! -x "$CLI" ]; then
  CLI="makori run -p cli --"
fi

echo "bench SET/GET n=$N $HOST:$PORT"

start=$(date +%s)
i=0
while [ "$i" -lt "$N" ]; do
  $CLI -h "$HOST" -p "$PORT" SET k v >/dev/null
  i=$((i + 1))
done
mid=$(date +%s)
i=0
while [ "$i" -lt "$N" ]; do
  $CLI -h "$HOST" -p "$PORT" GET k >/dev/null
  i=$((i + 1))
done
end=$(date +%s)

set_s=$((mid - start))
get_s=$((end - mid))
if [ "$set_s" -eq 0 ]; then set_s=1; fi
if [ "$get_s" -eq 0 ]; then get_s=1; fi
echo "SET  $N in ${set_s}s  ($((N / set_s))/s)"
echo "GET  $N in ${get_s}s  ($((N / get_s))/s)"
