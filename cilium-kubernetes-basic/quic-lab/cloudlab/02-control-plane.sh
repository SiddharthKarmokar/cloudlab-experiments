#!/usr/bin/env bash
# Run on node0 only.
set -euo pipefail
API_IP="10.10.1.1"
POD_CIDR="10.244.0.0/16"
CILIUM_VERSION="${CILIUM_VERSION:-1.17.6}"

# --skip-phases=addon/kube-proxy: Cilium replaces kube-proxy entirely. Leaving
# kube-proxy in place would put iptables/IPVS in front of the UDP service path,
# which is exactly the variable this lab is trying to isolate.
sudo kubeadm init \
  --apiserver-advertise-address="$API_IP" \
  --pod-network-cidr="$POD_CIDR" \
  --skip-phases=addon/kube-proxy

mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

CLI_VER="$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
curl -sL --fail --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CLI_VER}/cilium-linux-amd64.tar.gz"
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm -f cilium-linux-amd64.tar.gz

EXP_NIC="$(cat /etc/quic-lab-nic)"

# loadBalancer.mode=dsr matters for QUIC specifically: in the default SNAT mode
# every reply is rewritten by the node that received the request, so the origin
# never sees the real client address and return traffic is pinned through one
# extra hop. DSR returns straight from the backend. dsrDispatch=opt keeps the
# original destination in an IPv4 option rather than needing an outer header,
# so it does not eat into the QUIC MTU budget.
cilium install --version "$CILIUM_VERSION" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$API_IP" \
  --set k8sServicePort=6443 \
  --set devices="$EXP_NIC" \
  --set bpf.masquerade=true \
  --set loadBalancer.mode=dsr \
  --set loadBalancer.dsrDispatch=opt \
  --set loadBalancer.acceleration=native \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR="$POD_CIDR" \
  --set autoDirectNodeRoutes=true \
  --set installNoConntrackIptablesRules=true

cilium status --wait

echo
echo "=== join command for node1 / node2 ==="
kubeadm token create --print-join-command
