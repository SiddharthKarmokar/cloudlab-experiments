#!/usr/bin/env bash
# E2 -- throughput and latency under load, per arm.
#
# Two request shapes on purpose:
#   small (/_whoami)  -- handshake- and syscall-bound; separates the passthrough
#                        arms' near-zero crypto cost from HAProxy's full TLS cost
#   page  (/)         -- data-plane-bound; separates per-datagram forwarding cost
#
# Each arm gets a warmup run that is discarded. Without it the first arm
# measured absorbs container page-in, DNS resolution and origin JIT warmup, and
# reliably looks 15-30% worse than it is.
set -euo pipefail
cd "$(dirname "$0")"; source ./lib.sh
preflight

CLIENTS="${CLIENTS:-100}"
STREAMS="${STREAMS:-10}"
REQUESTS="${REQUESTS:-50000}"
THREADS="${THREADS:-8}"
STAMP="$(date +%Y%m%dT%H%M%S)"
OUT="$RESULTS/e2-$STAMP"
mkdir -p "$OUT"

run_h2load() {
  local arm="$1" path="$2" tag="$3"
  local url; url="$(url_for "$arm" "$path")"
  lg "h2load --alpn-list=h3 -t $THREADS -c $CLIENTS -m $STREAMS -n $REQUESTS \
       --ca-file=/tmp/ca.crt '$url'" > "$OUT/${arm}-${tag}.txt" 2>&1
}

echo "E2: load  clients=$CLIENTS streams=$STREAMS requests=$REQUESTS threads=$THREADS"
echo "results -> $OUT"

for shape in "small:/_whoami" "page:/"; do
  tag="${shape%%:*}"; path="${shape##*:}"
  echo
  echo "### shape=$tag path=$path"
  for arm in "${ARMS[@]}"; do
    echo -n "  $arm: warmup... "
    lg "h2load --alpn-list=h3 -t 4 -c 20 -m 10 -n 2000 --ca-file=/tmp/ca.crt \
         '$(url_for "$arm" "$path")'" >/dev/null 2>&1 || true
    echo -n "measuring... "
    run_h2load "$arm" "$path" "$tag"
    echo "done"
  done
done

# ---------------------------------------------------------------------------
# Summarise. h2load prints 'finished in Xs, N req/s, B/s' and a latency block.
# ---------------------------------------------------------------------------
# On the latency line the label is three tokens:
#
#                        min      max     mean       sd    +/- sd
#   time for request:  1.23ms  45.6ms   5.67ms   3.21ms    89.00%
#
# so $4=min, $5=max, $6=mean. h2load emits no percentiles; max is its only tail
# signal, which is why the raw files are worth keeping.
summarise() {
  local f="$1" rps ok mean mx
  [ -f "$f" ] || { echo "NA|NA|NA|NA"; return; }
  rps="$(grep -oE '[0-9.]+ req/s' "$f" | head -1 | awk '{print $1}')"
  ok="$(grep -oE '[0-9]+ succeeded' "$f" | head -1 | awk '{print $1}')"
  mean="$(awk '/time for request:/ {print $6; exit}' "$f")"
  mx="$(awk '/time for request:/ {print $5; exit}' "$f")"
  printf '%s|%s|%s|%s\n' "${rps:-NA}" "${ok:-NA}" "${mean:-NA}" "${mx:-NA}"
}

echo
echo "E2 SUMMARY"
hr
printf '%-20s %-8s %-12s %-12s %-12s %-12s\n' ARM SHAPE REQ/S SUCCEEDED MEAN-LAT MAX-LAT
hr
for shape in small page; do
  for arm in "${ARMS[@]}"; do
    IFS='|' read -r rps ok mean mx <<<"$(summarise "$OUT/${arm}-${shape}.txt")"
    printf '%-20s %-8s %-12s %-12s %-12s %-12s\n' "$arm" "$shape" "$rps" "$ok" "$mean" "$mx"
  done
done
hr
echo "Raw h2load output in $OUT (keep it -- mean alone hides tail behaviour)"
