#!/usr/bin/env bash
# Two modes.
#
#   On node1 / node2:  sudo ./03-join-and-label.sh join <the kubeadm join command from 02>
#   On node0:          ./03-join-and-label.sh label
set -euo pipefail
MODE="${1:-}"
shift || true

case "$MODE" in
  join)
    [ $# -gt 0 ] || { echo "paste the full 'kubeadm join ...' command as arguments" >&2; exit 1; }
    sudo "$@"
    echo "joined -- now run './03-join-and-label.sh label' on node0"
    ;;
  label)
    kubectl wait --for=condition=Ready node/node1 node/node2 --timeout=300s
    kubectl label node node1 quic-lab/role=proxy --overwrite
    kubectl label node node2 quic-lab/role=app   --overwrite
    # The proxy node carries hostNetwork listeners on well-known ports and the
    # app node carries the origin; keeping ordinary workloads off the proxy node
    # stops the Boutique pods from stealing CPU from the thing being measured.
    kubectl taint node node1 quic-lab/proxy-only=true:NoSchedule --overwrite
    kubectl get nodes -o wide --show-labels
    ;;
  *)
    echo "usage: $0 {join <cmd...>|label}" >&2
    exit 1
    ;;
esac
