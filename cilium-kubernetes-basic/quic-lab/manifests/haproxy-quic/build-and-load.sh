#!/usr/bin/env bash
# Build the QUIC-enabled HAProxy on node3 (the only node with Docker) and side-
# load it into node1's containerd. There is no registry in this lab, so the
# image travels as a tarball over the experiment LAN.
#
# Run from node3:  ./build-and-load.sh
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="quic-lab/haproxy-quic:local"
PROXY_NODE="${PROXY_NODE:-10.10.1.2}"
TAR="/tmp/haproxy-quic.tar"

echo "==> building $IMAGE (AWS-LC + HAProxy, ~5-8 min on a c6525)"
docker build -t "$IMAGE" .

echo "==> QUIC support as compiled:"
docker run --rm --entrypoint haproxy "$IMAGE" -vv | grep -iE 'quic|aws-lc|version' || true

echo "==> exporting and side-loading onto the proxy node ($PROXY_NODE)"
docker save "$IMAGE" -o "$TAR"
scp -o StrictHostKeyChecking=no "$TAR" "${PROXY_NODE}:${TAR}"
# -n k8s.io is required: images imported into the default namespace are
# invisible to the kubelet.
ssh -o StrictHostKeyChecking=no "$PROXY_NODE" \
  "sudo ctr -n k8s.io images import ${TAR} && sudo ctr -n k8s.io images ls | grep haproxy-quic"
rm -f "$TAR"

echo "==> done. The Deployment uses imagePullPolicy: Never against $IMAGE"
