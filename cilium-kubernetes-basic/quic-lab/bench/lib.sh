#!/usr/bin/env bash
# Shared definitions for the experiment scripts. Source, do not execute.
# All experiment scripts run on node3 (the load generator), outside the cluster.

PROXY_IP="${PROXY_IP:-10.10.1.2}"
DOMAIN="${DOMAIN:-boutique.quic-lab.test}"
CA="${CA:-/tmp/ca.crt}"
IMAGE="${IMAGE:-quic-lab/h2load-h3:local}"
RESULTS="${RESULTS:-$HOME/quic-lab-results}"

# arm name -> port. Ordered so tables come out consistently.
ARMS=(envoy-passthrough nginx-passthrough haproxy-terminate)
declare -A ARM_PORT=(
  [envoy-passthrough]=4443
  [nginx-passthrough]=4444
  [haproxy-terminate]=4445
)
declare -A ARM_KIND=(
  [envoy-passthrough]=passthrough
  [nginx-passthrough]=passthrough
  [haproxy-terminate]=termination
)

mkdir -p "$RESULTS"

die() { echo "ERROR: $*" >&2; exit 1; }
hr()  { printf '%.0s-' {1..72}; echo; }

# Run a command inside the load-gen image with the lab hostname pinned to the
# proxy node and the lab CA mounted.
lg() {
  docker run --rm --network host \
    --add-host "${DOMAIN}:${PROXY_IP}" \
    -v "${CA}:/tmp/ca.crt:ro" \
    -v "${RESULTS}:/results" \
    "$IMAGE" "$*"
}

url_for() { echo "https://${DOMAIN}:${ARM_PORT[$1]}${2:-/}"; }

preflight() {
  [ -f "$CA" ] || die "lab CA not found at $CA -- scp it from node0 (see certs/gen-certs.sh)"
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "load-gen image missing. Build it: docker build -t $IMAGE -f Dockerfile.h2load-h3 ."
}
