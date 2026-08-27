# Running the QUIC lab on CloudLab

Step-by-step for [quic-lab/](../quic-lab/) on the NSF CloudLab testbed. Budget
about **90 minutes** from zero to first result, most of it waiting on hardware
provisioning and two from-source container builds.

Nothing here has been executed against a live allocation — treat the first run
as a shakedown and check the log paths in [Troubleshooting](#troubleshooting)
when a step misbehaves.

---

## 0. Prerequisites (one time)

**An account in a CloudLab project.** Register at
[cloudlab.us](https://cloudlab.us/signup.php). You either join an existing
project or start one, and starting one needs a faculty PI — this is the step
with a multi-day lead time, so do it first. Everything below assumes your
account is already in an approved project.

**An SSH key uploaded.** CloudLab installs your *public* key on every node.
Manage → Account → SSH Keys. You never get a password; key auth is the only way in.

**The repo public on GitHub.** CloudLab clones over HTTPS with no credentials,
so a private repo silently fails to instantiate.

```bash
git add -A && git commit -m "quic lab" && git push origin main
```

Then confirm `https://github.com/SiddharthKarmokar/cloudlab-experiments` loads
in a logged-out browser. Note your remote is `git@github.com:…` (SSH) — that is
fine for pushing, but the URL you give CloudLab must be the **https://** form.

---

## 1. Create the profile

CloudLab reads a geni-lib script named `profile.py` from the **top level** of
the repository — which is why [profile.py](../../profile.py) sits at the repo
root rather than beside the lab it builds. The whole repo is cloned to
`/local/repository` on every node.

1. Experiments → **Create Experiment Profile**
2. Source: **Git Repository**
3. URL: `https://github.com/SiddharthKarmokar/cloudlab-experiments`
4. Branch: `main`
5. Name it something like `quic-passthrough-lab`, then **Create**

CloudLab parses `profile.py` immediately. A Python error surfaces here as a
parse failure rather than at instantiate time, so this doubles as your syntax
check.

To pick up later changes: open the profile → **Update** → *Update from
repository*. The profile does **not** auto-follow new commits, and forgetting
this is the most common way to spend twenty minutes debugging a script you
already fixed.

---

## 2. Instantiate

Click **Instantiate**, then:

| Field | Value |
|---|---|
| Hardware type | `c6525-25g` (default) |
| OS image | Ubuntu 24.04 (default) |
| Cluster | must actually have 4 free nodes of that type |
| Duration | 16 h default; extend later if needed |

**Check availability before committing.** The type must exist at the cluster you
choose, and popular types are often fully allocated:

- **Utah** — `c6525-25g` (16c/32t, 25 GbE), `xl170` (10c, 25 GbE), `m510`
- **Wisconsin** — `c220g5`, `c240g5` (both 10 GbE)
- **Clemson** — `c6420`, `r650`

Live counts are at [CloudLab resource
availability](https://www.cloudlab.us/resinfo.php). If `c6525-25g` is dry,
`xl170` is the closest substitute and needs no changes to the lab. Anything at
10 GbE rather than 25 GbE will lower absolute throughput in E2 but leaves every
*comparison* between arms valid — the arms all share the same ceiling.

Provisioning takes 5–15 minutes. The four nodes come up as `node0`–`node3` with
`10.10.1.1`–`10.10.1.4` on the experiment LAN.

### Wait for the startup scripts

The experiment reports **ready** before
[01-node-prep.sh](../quic-lab/cloudlab/01-node-prep.sh) has finished. That
script reclaims disk, sets the UDP sysctls, and installs containerd and kubeadm
— running step 3 early fails in confusing ways.

Watch the **Startup** column on the List View tab until all four say *finished*,
or check directly:

```bash
ssh -A <user>@<node0-hostname>
tail -f /local/logs/prep.log     # ends with "node prep complete"
```

---

## 2.5. Set up passwordless SSH between nodes

**IMPORTANT: Run this on all four nodes before proceeding to step 3.**

CloudLab installs your public key on all nodes, but not your private key. This
means `ssh node1` *from* node0 normally requires agent forwarding (`ssh -A`)
on every hop. Forgetting this at any point causes cascading **Permission denied
(publickey)** failures in later deploy scripts.

To avoid fragile agent forwarding chains, [00-node-ssh.sh](../quic-lab/cloudlab/00-node-ssh.sh)
mints a lab-scoped throwaway keypair, stores it on the NFS share, and installs
it on each node. The key is isolated to this experiment and dies with it — it
is **not** your CloudLab account key.

**On each of node0, node1, node2, and node3:**

```bash
cd /local/repository/cilium-kubernetes-basic/quic-lab
./cloudlab/00-node-ssh.sh
```

Each node reuses the same keypair (first run generates it, rest pick it up from
NFS), and adds it to `authorized_keys`. After this completes on all four nodes,
`ssh node1` works *without* `-A`.

---

## 3. Build the cluster

Node names resolve on the experiment LAN, so `ssh node1` works from node0 once
agent forwarding is on.

**On node0:**

```bash
cd /local/repository/cilium-kubernetes-basic/quic-lab
./cloudlab/02-control-plane.sh
```

This runs `kubeadm init` with kube-proxy skipped, installs Cilium as the
kube-proxy replacement in DSR mode, and prints a join command. Copy that whole
line — it contains a token that expires in 24 hours.

**On node1 and node2:**

```bash
cd /local/repository/cilium-kubernetes-basic/quic-lab
./cloudlab/03-join-and-label.sh join kubeadm join 10.10.1.1:6443 --token abc… --discovery-token-ca-cert-hash sha256:…
```

**Back on node0:**

```bash
./cloudlab/03-join-and-label.sh label
```

That waits for both workers, labels node1 `quic-lab/role=proxy` and node2
`quic-lab/role=app`, and taints node1 so Boutique pods cannot steal CPU from the
proxies being measured.

Sanity check before continuing:

```bash
kubectl get nodes -o wide -L quic-lab/role   # 3 Ready, INTERNAL-IP in 10.10.1.0/24
cilium status                                # all green
```

Node names appear as full experiment FQDNs —
`node1.<experiment>.<project>-pg0.<site>.cloudlab.us` — because that is the
hostname the kubelet registers. This is normal. The short names still work for
`ssh` (CloudLab puts them in `/etc/hosts`) but are **not** valid Kubernetes node
names, which is why the label step resolves nodes by their `10.10.1.x` address
instead.

If `INTERNAL-IP` shows a public address instead of `10.10.1.x`, the kubelet
picked the wrong interface — see [Troubleshooting](#troubleshooting).

---

## 4. Build the two images

Neither can be skipped, and both are from source. Start the HAProxy build first
and run the load-gen build while it finishes.

**On node3** (the only node with Docker):

```bash
cd /local/repository/cilium-kubernetes-basic/quic-lab

# ~5-8 min. HAProxy + AWS-LC, then side-loaded into node1's containerd.
./manifests/haproxy-quic/build-and-load.sh

# ~10 min. aws-lc -> nghttp3 -> ngtcp2 -> nghttp2 -> curl.
docker build -t quic-lab/h2load-h3:local -f bench/Dockerfile.h2load-h3 bench/
```

The official HAProxy image links stock OpenSSL and has no QUIC at all; no
maintained image ships `h2load` with HTTP/3. Both Dockerfiles assert the feature
is present and **fail the build** rather than producing a binary that silently
falls back — so a green build is meaningful.

There is no registry in this lab, which is why the HAProxy image travels to
node1 as a tarball over the experiment LAN.

If `docker` says permission denied, your shell predates the group change from
step 2: log out and back in, or `newgrp docker`.

---

## 5. Deploy

**On node0:**

```bash
cd /local/repository/cilium-kubernetes-basic/quic-lab
./deploy-all.sh
```

This applies Online Boutique, generates the lab CA and leaf cert, and brings up
the QUIC origin plus all three proxy arms. It prints the listener map:

```
UDP 4443  envoy-passthrough    -> quic-origin (nginx h3) -> boutique frontend
UDP 4444  nginx-passthrough    -> quic-origin (nginx h3) -> boutique frontend
UDP 4445  haproxy-terminate    -> boutique frontend   (terminates QUIC itself)
```

All three run **concurrently** on different ports. That is deliberate: swapping
arms in and out between runs means each is measured against a differently-warmed
cluster.

If the HAProxy arm reports SKIPPED, step 4's side-load did not land — check with
`ssh node1 'sudo ctr -n k8s.io images ls | grep haproxy'`.

---

## 6. Run the experiments

**On node3:**

```bash
scp node0:/local/repository/cilium-kubernetes-basic/quic-lab/certs/out/ca.crt /tmp/ca.crt
cd /local/repository/cilium-kubernetes-basic/quic-lab/bench

./e1-functional.sh        # gate: do not continue until all three arms pass
./e6-buffer-cliff.sh      # run BEFORE trusting E2
./e2-load.sh
./e3-client-identity.sh
./e4-migration.sh
./e5-cpu-cost.sh
```

E6 before E2 is not a typo. Stock Linux UDP buffers make a QUIC proxy look slow
when the kernel is actually discarding datagrams; E6 tells you whether you are
measuring the proxy or the socket.

E4 and E5 drive `kubectl` on node0 over SSH — another reason agent forwarding
must be live in the shell you run them from.

Results land in `~/quic-lab-results/`. **Copy them off the node before the
experiment expires**, or they are gone:

```bash
# from your laptop
scp -r <user>@<node3-hostname>:~/quic-lab-results ./results-$(date +%F)
```

---

## 7. Keep or release the allocation

Experiments terminate automatically at expiry and **all disk state is
destroyed** — there is no snapshot of your results.

- **Extend**: experiment page → Extend, with a justification. Short extensions
  are usually automatic; multi-day ones need approval.
- **Terminate** as soon as you are done. CloudLab is shared and free; sitting on
  four bare-metal nodes idle is the thing that gets accounts throttled.

To preserve a configured node for later, use **Create Disk Image** on it before
terminating, then set that image in the profile.

---

## Troubleshooting

**Startup script failed.** Read `/local/logs/prep.log` on the node — every step
logs with a `[prep:<role>]` prefix. It is idempotent, so re-run it directly:

```bash
sudo bash /local/repository/cilium-kubernetes-basic/quic-lab/cloudlab/01-node-prep.sh proxy
```

**`Permission denied (publickey)` between nodes.** Agent forwarding is not
active. Reconnect from your laptop with `ssh -A`, and confirm with `ssh-add -l`
on the node — it must list your key, not error.

**`Error from server (NotFound): nodes "node1" not found`.** The kubelet
registered under the experiment FQDN, not the short name. Confirm the label step
is resolving by IP rather than hostname:

```bash
kubectl get nodes --no-headers \
  -o 'custom-columns=NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address'
```

Both workers must appear with `10.10.1.2` and `10.10.1.3`. If one is missing it
never joined — re-run the join command on that node.

**Node `INTERNAL-IP` is a public address.** The kubelet did not pick the
experiment NIC, so pod traffic leaves the fast fabric. Check
`cat /etc/default/kubelet` for `--node-ip=10.10.1.x`, then
`sudo systemctl restart kubelet`. If the file is empty, prep ran before the LAN
interface was configured — re-run it and rejoin the node.

**Disk full during an image build.** `mkextrafs` did not reclaim the spare
partition. Check with `df -h /mnt/extra`; if missing, run
`sudo /usr/local/etc/emulab/mkextrafs.pl -f /mnt/extra` and re-run prep so
`/var/lib/containerd` gets symlinked before containerd writes to the root disk.

**Cilium pods CrashLooping.** Almost always a wrong `devices=` value. Compare
`cat /etc/quic-lab-nic` against `ip -o -4 addr show | grep 10.10.1`, then
`cilium uninstall` and re-run step 3.

**E1 fails on one arm only.** Check that arm's pod:
`kubectl -n quic-lab logs deploy/<arm>`. For `haproxy-terminate`, first confirm
QUIC is compiled in — `ssh node1 'sudo ctr -n k8s.io images ls | grep haproxy'`
— since a QUIC-less HAProxy starts fine and simply never answers on UDP.

**E1 fails on every arm.** Suspect the origin, not the proxies:
`kubectl -n quic-lab logs deploy/quic-origin`. If it complains about
`http_v3_module`, your `nginx:mainline` tag lacks QUIC:

```bash
docker run --rm nginx:mainline nginx -V 2>&1 | tr ' ' '\n' | grep -E 'v3|quic'
```

**Hardware type unavailable at instantiate.** Pick another cluster, or switch to
`xl170`. Absolute throughput moves; comparisons between arms do not.

---

## Reference

- Lab design, per-arm rationale, and how to read each result: [quic-lab/README.md](../quic-lab/README.md)
- Topology and node roles: [profile.py](../../profile.py)
- [CloudLab manual](https://docs.cloudlab.us/) · [repository-based profiles](https://docs.cloudlab.us/creating-profiles.html) · [geni-lib](https://docs.cloudlab.us/geni-lib.html) · [resource availability](https://www.cloudlab.us/resinfo.php)
