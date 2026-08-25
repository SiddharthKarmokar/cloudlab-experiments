#!/usr/bin/env bash
# Run on node0 once the cluster is up and labelled.
# Brings up the Boutique app, the QUIC origin, and all three proxy arms.
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"

echo "==> Online Boutique (the workload under test)"
kubectl apply -k "$REPO_ROOT/deploy/base"

echo "==> lab certificates"
./certs/gen-certs.sh

echo "==> QUIC origin + headless view"
kubectl apply -f manifests/10-quic-origin.yaml
kubectl apply -f manifests/11-origin-headless.yaml

echo "==> passthrough arms"
kubectl apply -f manifests/20-envoy-passthrough.yaml
kubectl apply -f manifests/30-nginx-passthrough.yaml

echo "==> termination arm (requires the side-loaded image; see manifests/haproxy-quic/)"
if ssh -o StrictHostKeyChecking=no 10.10.1.2 \
     "sudo ctr -n k8s.io images ls -q | grep -q quic-lab/haproxy-quic"; then
  kubectl apply -f manifests/40-haproxy-terminate.yaml
else
  echo "    SKIPPED: quic-lab/haproxy-quic:local is not on node1."
  echo "    Build it first from node3: manifests/haproxy-quic/build-and-load.sh"
fi

echo "==> waiting for rollouts"
kubectl -n online-boutique rollout status deploy/frontend --timeout=300s
kubectl -n quic-lab rollout status deploy/quic-origin --timeout=300s
kubectl -n quic-lab rollout status deploy/envoy-passthrough --timeout=180s
kubectl -n quic-lab rollout status deploy/nginx-passthrough --timeout=180s
kubectl -n quic-lab rollout status deploy/haproxy-terminate --timeout=180s 2>/dev/null || true

echo
kubectl -n quic-lab get pods -o wide
echo
cat <<'EOF'
Listeners now up on node1 (10.10.1.2):
  UDP 4443  envoy-passthrough    -> quic-origin (nginx h3) -> boutique frontend
  UDP 4444  nginx-passthrough    -> quic-origin (nginx h3) -> boutique frontend
  UDP 4445  haproxy-terminate    -> boutique frontend   (terminates QUIC itself)

Next, from node3:
  scp node0:~/.../quic-lab/certs/out/ca.crt /tmp/ca.crt
  docker build -t quic-lab/h2load-h3:local -f bench/Dockerfile.h2load-h3 bench/
  ./bench/e1-functional.sh
EOF
