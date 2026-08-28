#!/usr/bin/env bash
# E6 -- the UDP receive-buffer cliff.
#
# Run this before you believe any number from E2. Linux ships ~208 KB default
# UDP socket buffers. A QUIC proxy at load overruns that and the kernel drops
# datagrams silently -- the symptom is "the proxy is slow" or "QUIC is worse
# than TCP", and the cause is a sysctl. 01-node-prep.sh already raises the
# limits; this experiment shows what they are worth by putting them back.
#
# Reverts to the tuned values on exit, including on failure.
set -euo pipefail
cd "$(dirname "$0")"; source ./lib.sh
preflight

PROXY_SSH="${PROXY_SSH:-ssh -o StrictHostKeyChecking=no $PROXY_IP}"
ARM="${ARM:-nginx-passthrough}"
DURATION="${DURATION:-20}"
TUNED=33554432
STOCK=212992

apply_bufs() {
  local v="$1"
  $PROXY_SSH "sudo sysctl -qw net.core.rmem_max=$v net.core.wmem_max=$v \
                                net.core.rmem_default=$v net.core.wmem_default=$v"
  sudo sysctl -qw net.core.rmem_max="$v" net.core.wmem_max="$v" \
                  net.core.rmem_default="$v" net.core.wmem_default="$v"
  # Sockets read their buffer size at creation, so the proxy must be restarted
  # for the change to reach the listener. Without this the experiment silently
  # measures nothing.
  ssh -o StrictHostKeyChecking=no 10.10.1.1 \
    "kubectl -n quic-lab rollout restart deploy/$ARM && \
     kubectl -n quic-lab rollout status deploy/$ARM --timeout=120s" >/dev/null
}

restore() {
  echo
  echo "restoring tuned buffers..."
  apply_bufs "$TUNED" || true
}
trap restore EXIT

measure() {
  lg "h2load --h3 -t 8 -c 200 -m 10 -D $DURATION \
       '$(url_for "$ARM" /)'" 2>&1
}

udp_errors() {
  $PROXY_SSH "cat /proc/net/snmp" | awk '/^Udp:/ && !/InDatagrams/ {print $4+0, $6+0}' | tail -1
}

echo "E6: UDP buffer sensitivity on arm=$ARM (${DURATION}s runs)"
hr
printf '%-16s %-14s %-16s %s\n' RMEM/WMEM REQ/S 'UDP RCVBUF-ERR' 'UDP IN-ERR'
hr

for v in "$STOCK" "$TUNED"; do
  apply_bufs "$v"
  read -r err_before_in err_before_buf <<<"$(udp_errors)"
  out="$(measure)"
  read -r err_after_in err_after_buf <<<"$(udp_errors)"

  rps="$(echo "$out" | grep -oE '[0-9.]+ req/s' | head -1 | awk '{print $1}')"
  label="$(awk -v v="$v" 'BEGIN{printf "%d KB", v/1024}')"
  printf '%-16s %-14s %-16s %s\n' "$label" "${rps:-NA}" \
    "$(( err_after_buf - err_before_buf ))" "$(( err_after_in - err_before_in ))"
done
hr

cat <<'NOTE'

Reading the result
------------------
If the 208 KB row shows materially lower req/s AND a non-zero RcvbufErrors
delta, the buffer was the binding constraint -- the proxy was never the
bottleneck, the socket was. That is the single most common way a QUIC proxy
benchmark produces a wrong conclusion.

RcvbufErrors is the honest signal here. Throughput alone cannot distinguish
"the proxy is saturated" from "the kernel threw the traffic away before the
proxy saw it".
NOTE
