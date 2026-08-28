# QUIC passthrough vs termination — experiment report

Run of 2026-08-28 on CloudLab Utah, `c6525-25g` bare metal, Ubuntu 24.04
(kernel 6.8), Kubernetes 1.33 with Cilium 1.17.6 in kube-proxy-replacement /
DSR mode. Lab under test: [quic-lab/](../quic-lab/).

**Status: partial.** One of three arms is not serving, and one of the two
request shapes produced invalid data. Read [What is and isn't
valid](#what-is-and-isnt-valid) before quoting any number here.

---

## The three arms

| Arm | Port | Mode | QUIC terminated by | Path |
|---|---|---|---|---|
| `envoy-passthrough` | UDP 4443 | passthrough | `quic-origin` (nginx) | client → Envoy (L4) → origin → Boutique |
| `nginx-passthrough` | UDP 4444 | passthrough | `quic-origin` (nginx) | client → nginx `stream` (L4) → origin → Boutique |
| `haproxy-terminate` | UDP 4445 | **termination** | HAProxy itself | client → HAProxy → Boutique |

The asymmetry is deliberate and unavoidable: **open-source HAProxy has no UDP
forwarding mode**, so QUIC passthrough is not available to it. Its QUIC support
is a listener (`bind quic4@`) that terminates. UDP load balancing exists only in
HAProxy Enterprise's `udp-lb` section. The third arm therefore answers a
different question — "what do you get back by giving up passthrough?" — and its
numbers must never be quoted as "HAProxy passthrough performance".

Empirical confirmation from the build: HAProxy 3.2.23 reports
`quic : mode=HTTP side=FE mux=QUIC`. Frontend side only; it cannot originate
QUIC toward a backend.

---

## What each experiment does

### E1 — functional gate
Sends one HTTP/3 request through each arm with `curl --http3-only`. The
`-only` matters: it refuses to fall back to TCP, so a pass is proof that QUIC
actually worked rather than that something answered. Everything downstream
assumes E1 is green.

### E2 — throughput and latency
`h2load` over HTTP/3 at fixed concurrency, in two request shapes:

- **small** (`/_whoami`) — a synthetic endpoint returning a few bytes.
  Handshake- and syscall-bound. Isolates the cost of the QUIC edge itself.
- **page** (`/`) — the real Boutique homepage, ~10.5 KB through the whole
  microservice chain. Data-plane- and backend-bound.

Two shapes because they stress different things: the small shape can separate
proxies that are otherwise indistinguishable once a real backend dominates.

### E3 — client identity
Asks each arm's backend what address it believes the client is. This is the
experiment that makes the passthrough/termination distinction concrete rather
than theoretical.

### E4 — connection migration
A QUIC connection is identified by its connection ID, not its 4-tuple, and
clients change address routinely (NAT rebind, wifi→cellular). Both passthrough
proxies key their session tables on the 4-tuple and neither parses connection
IDs, so a rebind creates a *new* proxy session that is re-load-balanced from
scratch. Harmless with one origin; a coin flip with several. Run in two
regimes — 1 origin, then 3 — using a client that can force a NAT rebinding on
demand.

### E5 — CPU cost per request
Cumulative CPU from each proxy's own cgroup, divided by requests served.
E2 measures what the client sees; E5 measures what the operator pays.

### E6 — UDP buffer sensitivity
Reruns a load with stock (~208 KB) vs tuned (32 MB) UDP socket buffers and
reports `RcvbufErrors` alongside throughput. Run this **before** trusting E2:
it distinguishes "the proxy is saturated" from "the kernel discarded the
traffic before the proxy saw it", which is the single most common way a QUIC
benchmark reaches a wrong conclusion.

---

## Results

### E1 — functional

| Arm | HTTP/3 | Boutique homepage |
|---|---|---|
| `envoy-passthrough` | **FAIL** — `curl (55)` after 10 s | 0 bytes |
| `nginx-passthrough` | pass | 10,499 bytes |
| `haproxy-terminate` | pass | 10,499 bytes |

Identical byte counts on the two working arms confirm the full chain — QUIC
edge, origin, frontend, backing microservices — is intact.

### E2 — small shape (`/_whoami`), 50,000 requests, 100 connections × 10 streams

| Arm | req/s | Succeeded | Mean | p95 | p99 | Max |
|---|---|---|---|---|---|---|
| `nginx-passthrough` | **262,211** | 50,000 / 50,000 | 2.08 ms | 3.36 ms | **50.13 ms** | 54.37 ms |
| `haproxy-terminate` | **158,393** | 50,000 / 50,000 | 4.67 ms | 6.28 ms | **8.24 ms** | 17.93 ms |
| `envoy-passthrough` | 0 | 0 / 50,000 | — | — | — | — |

Two things here, pulling in opposite directions:

**Throughput favours passthrough, 1.66×.** Consistent with the mechanism: the
passthrough arm's edge proxy does no cryptography, only datagram forwarding.

**Tail latency favours termination, and by more.** nginx's p99 of 50 ms is 6×
HAProxy's 8 ms, despite a better mean and p95. A path that is faster in the
middle and much worse in the tail is the signature of queueing or scheduling
variance introduced by the extra hop — the passthrough arm crosses the network
twice and terminates QUIC on a *different node*. If you care about p99, the
throughput headline is misleading.

### E2 — page shape (`/`) — **INVALID, see below**

| Arm | req/s | Succeeded | 5xx | Mean TTFB |
|---|---|---|---|---|
| `nginx-passthrough` | 395.93 | 9,963 / 50,000 | 40,029 | 14.41 s |
| `haproxy-terminate` | 52,867 | **0** / 50,000 | 50,000 | — |

### E3 — client identity

| Arm | Mode | Backend sees | Verdict |
|---|---|---|---|
| `nginx-passthrough` | passthrough | `10.10.1.2` | **client IP lost** (the proxy) |
| `haproxy-terminate` | termination | `10.10.1.4` | client preserved |

The cleanest result in this run, and it is not a configuration artifact.
TLS-over-TCP passthrough can carry the client address in a PROXY protocol
header; QUIC passthrough cannot, because neither nginx's `stream` module nor
Envoy's `udp_proxy` has a UDP PROXY encoding the origin would accept.

Consequences worth weighing before choosing passthrough at an edge:

- per-client rate limiting and abuse blocking must move to the origin, whose
  view is now a single proxy address — it cannot distinguish clients at all
- geo/ASN logic, audit logging, and any source-IP allow-list break
- QUIC's own address validation and anti-amplification limits are computed
  against the proxy's address, not the client's

Mitigations, both with real cost: transparent proxying (`proxy_bind …
transparent`, needing `CAP_NET_ADMIN` on the proxy and policy routing on the
origin node), or terminating at the edge.

### E4, E5, E6

No valid data yet. See below.

---

## What is and isn't valid

**Trustworthy:**

- **E3.** Fully clean, and the mechanism is well understood.
- **E1** for the two working arms.

**Suggestive but weak — E2 small shape.** Two independent problems:

1. **The measurement window is far too short.** 50,000 requests completed in
   191 ms (nginx) and 316 ms (HAProxy). A sub-second sample is dominated by
   connection establishment and scheduler noise; `connect` alone averaged
   ~12 ms. These are burst figures, not steady-state throughput, and should be
   rerun with `h2load -D 30` for a fixed 30-second duration instead of `-n`.
2. **It is not really passthrough-vs-termination.** Both arms terminate QUIC —
   the passthrough arm just does it at `quic-origin` (nginx) instead of at the
   edge. So E2-small largely compares **nginx's QUIC stack against HAProxy's
   QUIC stack**, plus one L4 hop. The correct reading is "nginx terminating
   behind an L4 forwarder beat HAProxy terminating at the edge", not
   "passthrough is faster than termination".

**Invalid — E2 page shape.** The Boutique `frontend` Deployment runs **1
replica with `limits.cpu: 200m`**. Fifty thousand requests against a
fifth-of-a-core pod saturates it immediately, and both arms then measured how
fast a collapsed backend emits 503s — nginx by queueing (14.4 s TTFB, 20%
completion over 126 s), HAProxy by failing fast (50,000 5xx in 946 ms, almost
certainly its `option httpchk` health check marking the backend DOWN and
returning 503 without forwarding). Neither number describes a proxy.

**Absent — `envoy-passthrough`.** Its `udp_proxy` cluster never acquired an
endpoint: Envoy resolves with its own c-ares resolver over unconnected UDP, and
from the host network namespace Cilium's socket-LB does not translate that
path. Every lookup failed, visible as `cluster.quic_origin.update_failure`
climbing in Envoy's admin `/stats` while the listener itself looked healthy.
nginx is unaffected because glibc `connect()`s its DNS socket, which Cilium's
`connect4` hook does rewrite — and nginx sends UDP to that same ClusterIP
successfully, so the data path was never the problem.

That is a finding in its own right, independent of QUIC: **Envoy's DNS
resolution does not work from `hostNetwork` on a Cilium kube-proxy-replacement
node, while nginx's does.** The fix applied pins Envoy's upstream to the
origin's ClusterIP literal, sidestepping resolution entirely.

**Not yet run — E4, E5, E6.** All three were blocked by harness bugs rather
than by the lab: every `h2load` call passed `--ca-file`, which h2load does not
accept (it does not verify server certificates at all), so E2/E5/E6 exited
immediately and reported empty tables. E4 additionally uses a QUIC client whose
flags are still unverified, and repoints Envoy at a DNS name it cannot resolve.

---

## What to fix before these numbers are publishable

1. **Provision the backend for load.** `frontend` at 1 × 200m CPU cannot serve
   the page shape. Scale replicas and raise limits until the frontend is
   demonstrably not the bottleneck, or the page shape will keep measuring the
   Boutique instead of the proxies.
2. **Switch E2 to duration-based measurement.** `-D 30` rather than `-n 50000`,
   so the sample is steady-state.
3. **Land the Envoy ClusterIP fix** and confirm all three arms pass E1.
4. **Run E6 before re-reading E2.** Nothing in the current E2 numbers is
   corroborated against `RcvbufErrors`, so it is not yet known whether the
   kernel was dropping datagrams.
5. **Verify E4's client flags**, then rewrite it to inject origin pod IPs
   directly rather than a DNS name.
6. **Report p99 alongside req/s.** The tail inversion in E2-small is the more
   operationally interesting signal and a throughput-only table hides it.

---

## Reproducing

Full setup: [cloudlab-runbook.md](cloudlab-runbook.md). Lab design and the
rationale for each configuration choice: [quic-lab/README.md](../quic-lab/README.md).

Raw `h2load` output for this run is under `~/quic-lab-results/e2-*/` on the
load generator and is **not** preserved when the CloudLab experiment expires —
copy it off before termination.
