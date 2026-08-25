#!/usr/bin/env bash
# E3 -- what does the thing behind the proxy believe the client is?
#
# This is the experiment that makes the passthrough/termination distinction
# concrete rather than theoretical. TLS-over-TCP passthrough can carry the
# client address in the PROXY protocol header; QUIC passthrough cannot, because
# neither nginx's stream module nor Envoy's udp_proxy has a UDP PROXY-protocol
# encoding that the origin would accept. So the origin sees the proxy.
#
# Expected: both passthrough arms report the PROXY node's address (10.10.1.2),
# HAProxy reports this load generator's address (10.10.1.4).
set -euo pipefail
cd "$(dirname "$0")"; source ./lib.sh
preflight

MY_IP="$(ip -o -4 addr show | awk '/10\.10\.1\./ {split($4,a,"/"); print a[1]; exit}')"
echo "E3: client identity as observed by the backend"
echo "this load generator is $MY_IP; the proxy node is $PROXY_IP"
hr
printf '%-20s %-13s %-18s %s\n' ARM KIND BACKEND-SEES VERDICT
hr

for arm in "${ARMS[@]}"; do
  body="$(lg "curl -sS --http3-only --cacert /tmp/ca.crt '$(url_for "$arm" /_whoami)'" 2>/dev/null || echo '{}')"
  seen="$(echo "$body" | jq -r '.remote_addr // "?"' 2>/dev/null || echo '?')"

  case "$seen" in
    "$MY_IP")    verdict="client preserved" ;;
    "$PROXY_IP") verdict="CLIENT IP LOST (proxy address)" ;;
    *)           verdict="unexpected: $seen" ;;
  esac
  printf '%-20s %-13s %-18s %s\n' "$arm" "${ARM_KIND[$arm]}" "$seen" "$verdict"
done
hr

cat <<'NOTE'

Reading the result
------------------
The passthrough arms losing the client address is correct behaviour, not a
misconfiguration. Consequences to weigh before choosing passthrough at an edge:

  * per-client rate limiting and abuse blocking must move to the origin's
    own view -- which is now a single proxy address, so it cannot distinguish
    clients at all
  * geo/ASN logic, audit logs and any allow-list keyed on source IP break
  * the QUIC address-validation and anti-amplification limits are computed by
    the origin against the proxy's address, not the client's

Two mitigations, both with real cost:
  * transparent proxying (nginx: proxy_bind $remote_addr transparent) -- needs
    CAP_NET_ADMIN on the proxy and policy routing on the origin node so replies
    return through the proxy; see 30-nginx-passthrough.yaml
  * terminate instead, as the HAProxy arm does
NOTE
