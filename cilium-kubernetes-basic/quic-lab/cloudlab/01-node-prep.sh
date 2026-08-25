#!/usr/bin/env bash
# Runs on every CloudLab node at instantiate time (or by hand: sudo ./01-node-prep.sh <role>).
# role: control | proxy | app | loadgen
set -euo pipefail
ROLE="${1:-app}"
K8S_MINOR="v1.33"
log() { echo "[prep:$ROLE] $*"; }

# ---------------------------------------------------------------------------
# 1. Storage. CloudLab images leave ~16 GB free on /, which containerd images
#    plus a proxy build will exhaust. Every node type ships unpartitioned space
#    that mkextrafs reclaims. Do this BEFORE installing containerd.
# ---------------------------------------------------------------------------
if [ ! -d /mnt/extra ]; then
  log "reclaiming spare disk into /mnt/extra"
  sudo mkdir -p /mnt/extra
  sudo /usr/local/etc/emulab/mkextrafs.pl -f /mnt/extra \
    || sudo /usr/local/etc/emulab/mkextrafs.pl /mnt/extra \
    || log "WARNING: mkextrafs failed; continuing on the root filesystem"
fi
for d in containerd kubelet; do
  if [ -d /mnt/extra ] && [ ! -L "/var/lib/$d" ]; then
    sudo mkdir -p "/mnt/extra/$d"
    sudo rm -rf "/var/lib/$d"
    sudo ln -s "/mnt/extra/$d" "/var/lib/$d"
  fi
done

# ---------------------------------------------------------------------------
# 2. Kernel + sysctl. The UDP buffer sizes are not optional garnish: Linux
#    defaults (~208 KB) cap a single QUIC flow at a few hundred Mbps and show
#    up as "the proxy is slow" when it is actually the socket dropping frames.
#    Both the proxies and the load generator need this.
# ---------------------------------------------------------------------------
sudo swapoff -a
sudo sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-quic-lab.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# QUIC needs deep UDP socket buffers on both ends.
net.core.rmem_max     = 33554432
net.core.wmem_max     = 33554432
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.core.netdev_max_backlog = 250000
net.core.optmem_max   = 8388608

# Large receive queues so a datagram burst is not dropped before userspace runs.
net.ipv4.udp_mem      = 786432 1048576 26777216
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072

fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 524288
EOF
sudo sysctl --system >/dev/null

# ---------------------------------------------------------------------------
# 3. NIC offloads on the experiment interface. UDP GRO forwarding is what lets
#    a passthrough proxy move QUIC at line rate instead of per-datagram syscall
#    rate. Detect the NIC by which one owns the 10.10.1.0/24 address.
# ---------------------------------------------------------------------------
EXP_NIC="$(ip -o -4 addr show | awk '/10\.10\.1\./ {print $2; exit}')"
if [ -n "${EXP_NIC:-}" ]; then
  log "experiment NIC = $EXP_NIC"
  sudo ethtool -K "$EXP_NIC" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true
  sudo ethtool -G "$EXP_NIC" rx 4096 tx 4096 2>/dev/null || true
  echo "$EXP_NIC" | sudo tee /etc/quic-lab-nic >/dev/null
else
  log "WARNING: no 10.10.1.x interface found yet"
fi

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  apt-transport-https ca-certificates curl gnupg jq ethtool socat conntrack tcpdump sysstat

# ---------------------------------------------------------------------------
# 4. The load generator is not a cluster member: it only needs Docker.
# ---------------------------------------------------------------------------
if [ "$ROLE" = "loadgen" ]; then
  curl -fsSL https://get.docker.com | sudo sh
  # This runs as root from the CloudLab startup service, so $(id -un) would add
  # *root* to the docker group and leave the human still needing sudo. CloudLab
  # home directories are /users/<username>, so grant every real account.
  for u in $(ls /users 2>/dev/null); do
    sudo usermod -aG docker "$u" 2>/dev/null && log "added $u to docker group" || true
  done
  log "loadgen ready (log out and back in for docker group to take effect)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. containerd + kubeadm on the three cluster nodes.
# ---------------------------------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd && sudo systemctl enable containerd

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Pin the kubelet to the experiment LAN. Without this it advertises the public
# control interface and every pod-to-pod hop leaves the fast fabric.
NODE_IP="$(ip -o -4 addr show | awk '/10\.10\.1\./ {split($4, a, "/"); print a[1]; exit}')"
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" | sudo tee /etc/default/kubelet >/dev/null
sudo systemctl daemon-reload

log "node prep complete (node-ip=${NODE_IP})"
