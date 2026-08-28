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
# Envoy's upstream is pinned to the origin's ClusterIP literal rather than its
# DNS name. Envoy resolves with its own c-ares resolver over unconnected UDP,
# and from the host network namespace Cilium's socket-LB does not translate
# that path -- every lookup fails and the cluster stays empty
# (cluster.quic_origin.update_failure climbing in Envoy's /stats). nginx is
# unaffected because glibc connects its DNS socket, which Cilium's connect4
# hook does rewrite. The UDP data path to the ClusterIP is fine either way,
# which is why nginx works; only the name resolution was broken.
#
# STRICT_DNS accepts an IP literal and skips the lookup, so the cluster type
# stays as-is and E4 can still repoint this at a multi-endpoint service.
kubectl apply -f manifests/30-nginx-passthrough.yaml
ORIGIN_CIP="$(kubectl -n quic-lab get svc quic-origin -o jsonpath='{.spec.clusterIP}')"
[ -n "$ORIGIN_CIP" ] || { echo "could not read quic-origin ClusterIP" >&2; exit 1; }
echo "    pinning envoy upstream to ${ORIGIN_CIP}:8443"
sed "s|address: quic-origin.quic-lab.svc.cluster.local|address: ${ORIGIN_CIP}|" \
  manifests/20-envoy-passthrough.yaml | kubectl apply -f -

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
  scp node0:/local/repository/cilium-kubernetes-basic/quic-lab/certs/out/ca.crt /tmp/ca.crt
  docker build -t quic-lab/h2load-h3:local -f bench/Dockerfile.h2load-h3 bench/
  ./bench/e1-functional.sh
EOF
