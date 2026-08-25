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
    # Nodes are addressed by their experiment-LAN IP, not by hostname. CloudLab
    # kubelets register under the full experiment FQDN
    # (node1.<exp>.<project>-pg0.<site>.cloudlab.us), so "node1" does not exist
    # as far as the API server is concerned. The IPs come from profile.py and
    # are the stable contract of this topology.
    node_by_ip() {
      kubectl get nodes --no-headers \
        -o 'custom-columns=NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address' \
        | awk -v ip="$1" '$2 == ip {print $1; exit}'
    }

    for _ in $(seq 1 60); do
      PROXY="$(node_by_ip 10.10.1.2)"
      APP="$(node_by_ip 10.10.1.3)"
      [ -n "$PROXY" ] && [ -n "$APP" ] && break
      echo "waiting for both workers to register..."
      sleep 5
    done
    [ -n "${PROXY:-}" ] || { echo "no node with InternalIP 10.10.1.2 (proxy)" >&2; exit 1; }
    [ -n "${APP:-}" ]   || { echo "no node with InternalIP 10.10.1.3 (app)"   >&2; exit 1; }

    echo "proxy node: $PROXY"
    echo "app node:   $APP"
    kubectl wait --for=condition=Ready "node/$PROXY" "node/$APP" --timeout=300s

    kubectl label node "$PROXY" quic-lab/role=proxy --overwrite
    kubectl label node "$APP"   quic-lab/role=app   --overwrite
    # The proxy node carries hostNetwork listeners on well-known ports and the
    # app node carries the origin; keeping ordinary workloads off the proxy node
    # stops the Boutique pods from stealing CPU from the thing being measured.
    kubectl taint node "$PROXY" quic-lab/proxy-only=true:NoSchedule --overwrite

    kubectl get nodes -o wide -L quic-lab/role
    ;;
  *)
    echo "usage: $0 {join <cmd...>|label}" >&2
    exit 1
    ;;
esac
