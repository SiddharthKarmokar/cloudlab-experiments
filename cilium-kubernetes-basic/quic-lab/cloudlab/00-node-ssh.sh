#!/usr/bin/env bash
# Give the lab nodes password-less ssh to each other. Run once on EVERY node.
#
# CloudLab installs your public key on the nodes but never your private key, so
# node-to-node ssh normally requires agent forwarding on every single hop. That
# is fragile -- one connection opened without `ssh -A` and deploy-all.sh, E4, E5
# and E6 all fail with "Permission denied (publickey)".
#
# Instead: mint one throwaway keypair and distribute it through the project's
# NFS share, which is already mounted on all four nodes. The key is scoped to
# this experiment and dies with it -- it is NOT your CloudLab account key, and
# nothing outside the experiment ever trusts it.
set -euo pipefail

KEY_NAME="quiclab_ed25519"
MARKER="# --- quic-lab node-to-node ssh ---"

PROJ_DIR="$(ls -d /proj/*/ 2>/dev/null | head -1)"
if [ -z "$PROJ_DIR" ]; then
  echo "ERROR: no /proj/<project> NFS mount found on this node." >&2
  echo "Fall back to agent forwarding: reconnect from your laptop with 'ssh -A'." >&2
  exit 1
fi
SHARE="${PROJ_DIR}quic-lab-ssh"
mkdir -p "$SHARE"
chmod 700 "$SHARE"

# First node to run this generates the pair; the rest reuse it off NFS.
if [ ! -f "$SHARE/$KEY_NAME" ]; then
  echo "==> minting lab keypair in $SHARE"
  ssh-keygen -t ed25519 -N '' -C "quic-lab" -f "$SHARE/$KEY_NAME"
  chmod 600 "$SHARE/$KEY_NAME"
else
  echo "==> reusing lab keypair from $SHARE"
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# A distinct filename so an existing ~/.ssh/id_* is never clobbered.
install -m 600 "$SHARE/$KEY_NAME" "$HOME/.ssh/$KEY_NAME"
install -m 644 "$SHARE/$KEY_NAME.pub" "$HOME/.ssh/$KEY_NAME.pub"

touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
PUB="$(cat "$SHARE/$KEY_NAME.pub")"
if ! grep -qxF "$PUB" "$HOME/.ssh/authorized_keys"; then
  echo "$PUB" >> "$HOME/.ssh/authorized_keys"
  echo "==> authorized the lab key on $(hostname -s)"
fi

# Host keys change every time an experiment is re-instantiated, so pinning them
# would only produce spurious MITM warnings on a testbed.
if ! grep -qF "$MARKER" "$HOME/.ssh/config" 2>/dev/null; then
  cat >> "$HOME/.ssh/config" <<EOF

$MARKER
Host 10.10.1.* node0 node1 node2 node3
  IdentityFile ~/.ssh/$KEY_NAME
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
  chmod 600 "$HOME/.ssh/config"
  echo "==> wrote ~/.ssh/config stanza"
fi

echo
echo "done on $(hostname -s). Run this on every node, then verify from any of them:"
echo "  for n in 10.10.1.1 10.10.1.2 10.10.1.3 10.10.1.4; do"
echo "    echo -n \"\$n -> \"; ssh -o BatchMode=yes \$n hostname -s || echo FAILED"
echo "  done"
