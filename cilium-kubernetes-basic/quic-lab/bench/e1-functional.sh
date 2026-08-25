#!/usr/bin/env bash
# E1 -- does an HTTP/3 request actually complete end to end through each arm?
#
# Run this first and do not proceed until all three arms are green. Every later
# experiment assumes the paths work; a silent TCP fallback would make the whole
# comparison meaningless, which is why --http3-only is used rather than --http3.
set -euo pipefail
cd "$(dirname "$0")"; source ./lib.sh
preflight

echo "E1: HTTP/3 reachability and negotiated protocol per arm"
hr
printf '%-20s %-6s %-12s %-9s %s\n' ARM PORT KIND HTTPVER BODY
hr

fail=0
for arm in "${ARMS[@]}"; do
  port="${ARM_PORT[$arm]}"
  url="$(url_for "$arm" /_whoami)"

  # --http3-only refuses to fall back, so a pass here is proof of QUIC.
  # The -w marker is tagged and newline-terminated so the JSON body that
  # follows cannot run onto the same line and defeat the match.
  out="$(lg "curl -sS --http3-only --cacert /tmp/ca.crt \
              -w 'VER=%{http_version} CODE=%{http_code}\n' -o /tmp/body \
              '$url' 2>&1; cat /tmp/body" || true)"

  ver="$(echo "$out" | grep -oE 'VER=3 CODE=2[0-9]{2}' | head -1 || true)"
  body="$(echo "$out" | grep -o '{.*}' | head -1 || true)"

  if [ -n "$ver" ]; then
    printf '%-20s %-6s %-12s %-9s %s\n' "$arm" "$port" "${ARM_KIND[$arm]}" "HTTP/3" "$body"
  else
    printf '%-20s %-6s %-12s %-9s %s\n' "$arm" "$port" "${ARM_KIND[$arm]}" "FAIL" "$(echo "$out" | head -2 | tr '\n' ' ')"
    fail=1
  fi
done
hr

# The real page, not just the synthetic endpoint -- confirms the whole chain
# down through the Boutique frontend is intact, not just the QUIC edge.
echo
echo "Boutique homepage through each arm (expect a non-trivial byte count):"
for arm in "${ARMS[@]}"; do
  bytes="$(lg "curl -sS --http3-only --cacert /tmp/ca.crt -o /dev/null \
                -w '%{size_download}' '$(url_for "$arm" /)'" 2>/dev/null || echo 0)"
  printf '  %-20s %s bytes\n' "$arm" "$bytes"
done

[ "$fail" -eq 0 ] || die "at least one arm failed HTTP/3 -- fix before running E2+"
echo
echo "E1 PASS"
