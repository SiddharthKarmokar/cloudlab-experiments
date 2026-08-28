# QUIC passthrough lab — Envoy vs nginx vs HAProxy on CloudLab

Puts the Online Boutique deployment in [deploy/base/](../deploy/base/) behind three
different QUIC edges on bare-metal CloudLab nodes, and measures what each one
costs and what each one gives up.

## The premise, corrected

The original goal was all three proxies in **passthrough** mode. Two of them can
do that; one cannot.

| Proxy | QUIC passthrough (L4 UDP forward) | QUIC termination (HTTP/3) |
|---|---|---|
| **Envoy** | yes — `envoy.filters.udp.udp_proxy` | yes |
| **nginx** | yes — `stream` + `listen … udp` | yes — `ngx_http_v3_module` |
| **HAProxy** | **no** — OSS HAProxy has no UDP forwarding mode at all | yes — `bind quic4@` |

HAProxy's QUIC support is a *listener*: it terminates. There is no `mode udp`
and no way to relay datagrams to a backend. UDP load balancing exists only in
HAProxy Enterprise's `udp-lb` section; HAProxy's own vendor guidance for
open-source UDP is to use LVS/IPVS instead of HAProxy.

So this lab runs **two passthrough arms and one termination arm**, and treats
that asymmetry as a result rather than hiding it. Arm C answers "what do you get
back by giving up passthrough?"

## Topology

```
node3  10.10.1.4   load generator (h2load/curl/quic-client over HTTP-3, outside the cluster)
   │
   │ UDP 4443 / 4444 / 4445
   ▼
node1  10.10.1.2   proxy tier — all three arms concurrently, hostNetwork
   ├── :4443  envoy    udp_proxy      ─┐
   ├── :4444  nginx    stream/udp     ─┤ opaque UDP, no keys held
   └── :4445  haproxy  quic4@ + h3     │ terminates, holds the key
                                       ▼
node2  10.10.1.3   quic-origin (nginx HTTP/3) — terminates for the passthrough arms
                          │ HTTP/1.1
                          ▼
                   Online Boutique frontend → the rest of the microservices
node0  10.10.1.1   kubeadm control plane + Cilium (kube-proxy replacement, DSR)
```

All three arms run **at the same time on different ports**, so no arm is
measured against a differently-warmed cluster. That is deliberate: tearing down
and redeploying between arms was the largest source of variance in early runs.

## Order of operations

> Full CloudLab walkthrough — account setup, profile creation, hardware
> selection, agent forwarding, teardown, and troubleshooting — is in
> **[docs/cloudlab-runbook.md](../docs/cloudlab-runbook.md)**. What follows is
> the condensed version for someone who already has an allocation.

**1. Instantiate.** Create a CloudLab experiment from
[profile.py](../../profile.py) with this repo as the profile source. CloudLab
only reads a top-level `profile.py`, so it lives at the repo root rather than
here. It requests four `c6525-25g` nodes on one unshaped LAN and runs
[cloudlab/01-node-prep.sh](cloudlab/01-node-prep.sh) on each.

The profile sets **no** `lan.bandwidth`. Asking CloudLab for a bandwidth
inserts a shaping node into the path, which would add jitter and invalidate
every latency number here.

**2. Cluster.** On node0:

```bash
./quic-lab/cloudlab/02-control-plane.sh        # kubeadm + Cilium, prints the join command
```

On node1 and node2, paste that join command:

```bash
./quic-lab/cloudlab/03-join-and-label.sh join kubeadm join 10.10.1.1:6443 --token …
```

Back on node0:

```bash
./quic-lab/cloudlab/03-join-and-label.sh label
```

**3. Verify the images actually have QUIC** — before deploying, not after a
confusing failure:

```bash
# nginx must list http_v3_module, for both the origin and the passthrough arm
docker run --rm nginx:mainline nginx -V 2>&1 | tr ' ' '\n' | grep -E 'v3|quic'
```

If `--with-http_v3_module` is absent from your nginx tag, pin a tag that has it
or swap the origin image; everything else in the lab is unaffected.

**4. HAProxy image.** The official HAProxy image has no QUIC (it links stock
OpenSSL). From node3, which is the only node with Docker:

```bash
./quic-lab/manifests/haproxy-quic/build-and-load.sh
```

That builds HAProxy against AWS-LC, asserts QUIC is compiled in, and side-loads
the image into node1's containerd — there is no registry in this lab.

**5. Deploy.** On node0:

```bash
./quic-lab/deploy-all.sh
```

**6. Load generator.** On node3:

```bash
scp node0:/local/repository/cilium-kubernetes-basic/quic-lab/certs/out/ca.crt /tmp/ca.crt
cd quic-lab/bench
docker build -t quic-lab/h2load-h3:local -f Dockerfile.h2load-h3 .
```

That image is a from-source build of aws-lc → nghttp3 → ngtcp2 → nghttp2 →
curl, because no maintained upstream image ships `h2load` with HTTP/3. It takes
roughly 10 minutes on a c6525 and fails the build rather than shipping a binary
without QUIC.

## Experiments

Run in order; E1 gates the rest.

| | Script | Question |
|---|---|---|
| **E1** | [e1-functional.sh](bench/e1-functional.sh) | Does HTTP/3 complete through each arm? Uses `--http3-only` so a silent TCP fallback fails rather than passes. |
| **E2** | [e2-load.sh](bench/e2-load.sh) | Throughput and latency, at two request shapes (handshake-bound vs data-bound). |
| **E3** | [e3-client-identity.sh](bench/e3-client-identity.sh) | What client address does the backend see? |
| **E4** | [e4-migration.sh](bench/e4-migration.sh) | Does a connection survive a NAT rebind — with one origin, and with three? |
| **E5** | [e5-cpu-cost.sh](bench/e5-cpu-cost.sh) | CPU microseconds per request at the edge. |
| **E6** | [e6-buffer-cliff.sh](bench/e6-buffer-cliff.sh) | How much of your result is really a UDP socket buffer? |

### What each one is expected to show

**E3 — client identity.** Both passthrough arms report the *proxy's* address to
the origin. This is inherent: TLS-over-TCP passthrough can carry the client in a
PROXY protocol header, but neither nginx's stream module nor Envoy's `udp_proxy`
has a UDP PROXY encoding the origin would accept. Rate limiting, geo logic, and
audit logging keyed on source IP all break. HAProxy, terminating, keeps it.

**E4 — connection migration.** This is the load-bearing trade-off. A QUIC
connection is identified by its connection ID, not its 4-tuple, and clients
change address routinely. Both passthrough proxies key sessions on the 4-tuple
and neither parses connection IDs, so a rebind creates a *new* session that is
re-load-balanced from scratch. With one origin that is harmless. With three, a
rebound connection survives only if it happens to hash back to the origin
holding its state — roughly a 1-in-3 coin flip. Not configurable away in either
proxy. Real fixes are one-upstream-per-listener, QUIC-LB-style connection IDs
that encode routing, or termination.

**E6 — run this before believing E2.** Linux ships ~208 KB UDP socket buffers.
A QUIC proxy overruns that and the kernel drops datagrams silently; the symptom
looks like "the proxy is slow" and the cause is a sysctl. E6 puts the stock
value back and reports `RcvbufErrors` alongside throughput, which is the only
signal that distinguishes a saturated proxy from a discarding kernel.

## Choices in here that are load-bearing

Things that will change your numbers if you alter them:

- **`use_per_packet_load_balancing: false`** (Envoy). Setting it true balances
  every datagram independently and destroys any QUIC connection the moment there
  is more than one endpoint. E4 turns it on deliberately.
- **`--base-id 7`** (Envoy). Its hot-restart domain socket is an abstract unix
  socket, scoped to the *network* namespace. On `hostNetwork` that is the host
  netns, where Cilium's `cilium-envoy` DaemonSet already owns `base_id=0`, and
  Envoy exits at startup. Any second Envoy on a Cilium node needs this.
- **`proxy_responses` left unset** (nginx). Any finite value tells nginx the
  session ends after that many datagrams, truncating QUIC mid-handshake.
- **`quic_bpf on`** (origin). Without it, each nginx worker owns a reuseport
  socket keyed on the 4-tuple, so a migrated connection hashes to a worker that
  has never seen its connection ID. That would confound E4 with an *origin*
  failure while measuring the *proxy*.
- **`tune.quic.socket-owner connection`** (HAProxy). Shared-listener-socket
  contention otherwise caps HAProxy's QUIC throughput well below line rate.
- **`dnsPolicy: ClusterFirstWithHostNet`** on every proxy. hostNetwork pods
  inherit the node's resolv.conf, which knows nothing about cluster DNS; without
  it the upstreams never resolve.
- **Cilium `loadBalancer.mode=dsr` with `dsrDispatch=opt`.** SNAT mode rewrites
  every reply at the receiving node, adding a hop and hiding the client.
  `opt` dispatch keeps the original destination in an IPv4 option rather than an
  outer header, so it does not eat the QUIC MTU budget.
- **kube-proxy skipped at `kubeadm init`.** Leaving it in place puts
  iptables/IPVS in front of the UDP service path — the exact variable this lab
  isolates.

## Known limits of this lab

- The load generator is a single node. Above roughly 25–30k req/s on the small
  shape, node3 becomes the bottleneck before any proxy does; check its CPU
  before reporting a proxy ceiling.
- Arm C is not apples-to-apples with A and B by construction, and its numbers
  should never be quoted as "HAProxy passthrough performance".
- Client-side QUIC is ngtcp2 for every arm, so results describe these proxies
  under *one* QUIC implementation. Chrome and quiche pace differently.
- One CA and one ECDSA P-256 leaf are shared by every terminator on purpose;
  differing key types would move the handshake cost between arms.
