#!/usr/bin/env bash
# E4 -- connection migration across a QUIC passthrough.
#
# The core hazard. A QUIC connection is identified by its connection ID, not by
# its 4-tuple: a client may change address or port (NAT rebind, wifi->cellular)
# and expect the connection to survive. Both passthrough proxies here key their
# session table on the 4-tuple and neither parses connection IDs. So a rebind
# creates a NEW proxy session, which is re-load-balanced from scratch.
#
# With one origin that is harmless -- the new session lands on the same place.
# With more than one it is a coin flip, and losing the flip kills the
# connection. This script demonstrates both regimes.
#
# Must be run from node0's kubectl context reachable over ssh, or set
# KUBECTL="ssh node0 kubectl".
set -euo pipefail
cd "$(dirname "$0")"; source ./lib.sh
preflight

KUBECTL="${KUBECTL:-ssh -o StrictHostKeyChecking=no 10.10.1.1 kubectl}"
TRIALS="${TRIALS:-20}"

# quic-client exits non-zero when the connection dies. --nat-rebinding forces a
# local port change mid-connection, which is exactly the event under test.
probe() {
  local arm="$1" rebind="$2" flag=""
  [ "$rebind" = yes ] && flag="--nat-rebinding"
  lg "quic-client $flag --exit-on-all-streams-close \
        ${DOMAIN} ${ARM_PORT[$arm]} '$(url_for "$arm" /_whoami)' \
        --ca-file=/tmp/ca.crt" >/dev/null 2>&1
}

trial_set() {
  local arm="$1" rebind="$2" ok=0
  for _ in $(seq 1 "$TRIALS"); do
    probe "$arm" "$rebind" && ok=$((ok+1)) || true
  done
  echo "$ok"
}

report() {
  local label="$1"
  echo
  echo "### $label"
  hr
  printf '%-20s %-14s %-14s\n' ARM 'NO REBIND' 'WITH REBIND'
  hr
  for arm in "${ARMS[@]}"; do
    a="$(trial_set "$arm" no)"
    b="$(trial_set "$arm" yes)"
    printf '%-20s %-14s %-14s\n' "$arm" "$a/$TRIALS" "$b/$TRIALS"
  done
  hr
}

# ---------------------------------------------------------------------------
# Regime 1: single origin behind a ClusterIP. Rebinding should survive
# everywhere, because there is nowhere else for the new session to go.
# ---------------------------------------------------------------------------
$KUBECTL -n quic-lab scale deploy/quic-origin --replicas=1
$KUBECTL -n quic-lab rollout status deploy/quic-origin --timeout=120s
report "Regime 1 -- 1 origin, ClusterIP (proxy sees a single upstream)"

# ---------------------------------------------------------------------------
# Regime 2: three origins behind the HEADLESS service, so the passthrough
# proxies resolve the real endpoint list and choose for themselves. Now a
# rebound session can be routed to an origin that has never seen the
# connection ID and has no way to recover it.
# ---------------------------------------------------------------------------
echo
echo "repointing passthrough arms at the headless service and scaling to 3..."
$KUBECTL -n quic-lab scale deploy/quic-origin --replicas=3
$KUBECTL -n quic-lab rollout status deploy/quic-origin --timeout=180s

for cm in envoy-passthrough-conf nginx-passthrough-conf; do
  $KUBECTL -n quic-lab get cm "$cm" -o yaml \
    | sed 's/quic-origin\.quic-lab/quic-origin-headless.quic-lab/g' \
    | $KUBECTL apply -f -
done
# nginx resolves upstreams once at config load and Envoy caches DNS, so both
# need a restart rather than a reload to pick up the new endpoint set.
$KUBECTL -n quic-lab rollout restart deploy/envoy-passthrough deploy/nginx-passthrough
$KUBECTL -n quic-lab rollout status deploy/envoy-passthrough --timeout=120s
$KUBECTL -n quic-lab rollout status deploy/nginx-passthrough --timeout=120s

report "Regime 2 -- 3 origins, headless (proxy load-balances across endpoints)"

cat <<'NOTE'

Reading the result
------------------
Regime 1 should be ~100% everywhere: with one upstream, a re-hashed session
still lands correctly and QUIC's own path validation absorbs the address change.

Regime 2 is the finding. The passthrough arms should drop to roughly
(1/replicas) success under rebinding -- a rebound connection survives only when
the new session happens to hash back to the origin that holds its state. The
HAProxy arm stays at ~100% because it terminates: it owns the connection ID
table itself and the rebinding never crosses a routing boundary.

This is the load-bearing trade-off of QUIC passthrough. It is not fixable by
configuration in either proxy, because neither parses QUIC connection IDs.
Real deployments solve it one of three ways:
  * one upstream per passthrough listener (what Regime 1 does), giving up
    horizontal scale behind the proxy
  * QUIC-aware L4 routing that hashes on the connection ID, which requires the
    origin to encode routing information into the CID it issues (the approach
    the QUIC-LB draft specifies)
  * terminate at the edge
NOTE

echo
echo "restoring: passthrough arms back to the ClusterIP, origin back to 1 replica"
for cm in envoy-passthrough-conf nginx-passthrough-conf; do
  $KUBECTL -n quic-lab get cm "$cm" -o yaml \
    | sed 's/quic-origin-headless\.quic-lab/quic-origin.quic-lab/g' \
    | $KUBECTL apply -f -
done
$KUBECTL -n quic-lab scale deploy/quic-origin --replicas=1
$KUBECTL -n quic-lab rollout restart deploy/envoy-passthrough deploy/nginx-passthrough
