#!/usr/bin/env bash
# E5 -- CPU cost per request at the proxy tier.
#
# E2 measures what the client sees. This measures what the operator pays. The
# expected shape: the passthrough arms burn CPU on datagram shuffling only
# (recvmsg/sendmsg, no crypto), while HAProxy additionally pays for the QUIC
# handshake, AEAD over every packet, and HTTP/3 framing.
#
# CPU is sampled from the pod cgroup rather than 'top', so it captures only the
# proxy under test even though all three share node1.
set -euo pipefail
cd "$(dirname "$0")"; source ./lib.sh
preflight

KUBECTL="${KUBECTL:-ssh -o StrictHostKeyChecking=no 10.10.1.1 kubectl}"
DURATION="${DURATION:-30}"
CLIENTS="${CLIENTS:-100}"
STREAMS="${STREAMS:-10}"
THREADS="${THREADS:-8}"
STAMP="$(date +%Y%m%dT%H%M%S)"
OUT="$RESULTS/e5-$STAMP"; mkdir -p "$OUT"

declare -A DEPLOY=(
  [envoy-passthrough]=envoy-passthrough
  [nginx-passthrough]=nginx-passthrough
  [haproxy-terminate]=haproxy-terminate
)

# Cumulative CPU microseconds from the pod's own cgroup v2 cpu.stat. Because
# all three arms share node1, node-level CPU would be useless here.
#
# The file is cat'd raw and parsed locally rather than running awk inside the
# container: KUBECTL is typically "ssh node0 kubectl", and an awk program with
# embedded quotes gets re-split by the remote shell and silently returns empty.
cpu_usec() {
  local dep="$1" pod
  pod="$($KUBECTL -n quic-lab get pod -l "app=$dep" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || true
  [ -n "$pod" ] || { echo 0; return; }
  $KUBECTL -n quic-lab exec "$pod" -- cat /sys/fs/cgroup/cpu.stat 2>/dev/null \
    | awk '/^usage_usec/ {print $2; found=1} END {if (!found) print 0}'
}

echo "E5: CPU microseconds consumed per successful request, ${DURATION}s per arm"
hr
printf '%-20s %-13s %-12s %-14s %-14s\n' ARM KIND REQUESTS CPU-SEC USEC/REQ
hr

for arm in "${ARMS[@]}"; do
  dep="${DEPLOY[$arm]}"

  # Warm the path so handshake caches and page faults are not attributed to the
  # measured window.
  lg "h2load --h3 -t 4 -c 20 -m 10 -n 2000 \
       '$(url_for "$arm" /_whoami)'" >/dev/null 2>&1 || true

  before="$(cpu_usec "$dep")"
  lg "h2load --h3 -t $THREADS -c $CLIENTS -m $STREAMS -D $DURATION \
       '$(url_for "$arm" /_whoami)'" \
     > "$OUT/${arm}.txt" 2>&1 || true
  after="$(cpu_usec "$dep")"

  reqs="$(grep -oE '[0-9]+ succeeded' "$OUT/${arm}.txt" | head -1 | awk '{print $1}')"
  reqs="${reqs:-0}"
  delta=$(( after - before ))

  if [ "$reqs" -gt 0 ]; then
    per="$(awk -v d="$delta" -v r="$reqs" 'BEGIN{printf "%.1f", d/r}')"
  else
    per="NA"
  fi
  cpus="$(awk -v d="$delta" 'BEGIN{printf "%.2f", d/1000000}')"
  printf '%-20s %-13s %-12s %-14s %-14s\n' "$arm" "${ARM_KIND[$arm]}" "$reqs" "$cpus" "$per"
done
hr

cat <<'NOTE'

Reading the result
------------------
usec/req is the number to compare; raw CPU-seconds are confounded by the
differing request counts each arm achieves in a fixed window.

Two costs are being separated here:
  * forwarding cost -- present in all three arms
  * cryptographic + HTTP/3 cost -- present only in the terminating arm

Note the passthrough arms do NOT get the crypto for free overall: the origin
pays it instead, just on a different node. To compare total system cost rather
than edge cost, add the origin's cgroup usage:

  kubectl -n quic-lab exec deploy/quic-origin -- awk '/usage_usec/ {print $2}' /sys/fs/cgroup/cpu.stat

Passthrough moves crypto off the edge; it does not remove it. The real argument
for passthrough is key custody and blast radius, not CPU.
NOTE
