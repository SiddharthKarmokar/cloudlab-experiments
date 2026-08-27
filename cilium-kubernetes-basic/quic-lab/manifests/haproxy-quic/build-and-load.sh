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

# Checked BEFORE the build, not after: the side-load needs key-based ssh to the
# proxy node, and discovering that at the end wastes an 8-minute compile.
# CloudLab installs your public key on the nodes but never your private key, so
# node-to-node ssh only works with a forwarded agent.
echo "==> preflight: ssh $PROXY_NODE"
if ! ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
        "$PROXY_NODE" true 2>/dev/null; then
  cat >&2 <<EOF

ERROR: cannot ssh to the proxy node ($PROXY_NODE) without a password.

CloudLab does not put your private key on the nodes, so this needs SSH agent
forwarding. From your laptop:

    ssh -A $(id -un)@<node3-hostname>
    ssh-add -l        # must list a key; "no identities" means the agent is empty

If the agent is empty, on your LAPTOP first:

    eval "\$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519

Then re-run this script -- the Docker build is cached, so it will be quick.

Alternative without agent forwarding: CloudLab NFS-mounts your project
directory on every node. Find it with 'ls /proj', then hand off through it:

    docker save $IMAGE -o /proj/<project>/haproxy-quic.tar
    # on node1:
    sudo ctr -n k8s.io images import /proj/<project>/haproxy-quic.tar

EOF
  exit 1
fi

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
