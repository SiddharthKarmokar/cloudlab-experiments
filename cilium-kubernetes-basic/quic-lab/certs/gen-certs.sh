#!/usr/bin/env bash
# Run on node0. Produces a lab CA and one leaf cert used by every QUIC terminator
# in the lab (the nginx origin, and HAProxy in termination mode), then loads them
# into the cluster as secrets.
#
# One shared leaf on purpose: if each proxy had its own cert the handshake cost
# would differ between arms and pollute the CPU comparison.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${OUT:-./out}"
DOMAIN="boutique.quic-lab.test"
NS="quic-lab"
mkdir -p "$OUT"

if [ ! -f "$OUT/ca.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -keyout "$OUT/ca.key" -out "$OUT/ca.crt" \
    -subj "/CN=quic-lab-ca"
fi

# ECDSA P-256 for the leaf. RSA-2048 signing dominates the handshake profile and
# would make the termination arm look worse than any real deployment.
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$OUT/tls.key" -out "$OUT/tls.csr" \
  -subj "/CN=${DOMAIN}"

cat > "$OUT/ext.cnf" <<EOF
subjectAltName = DNS:${DOMAIN}, DNS:quic-edge, DNS:quic-edge.${NS}.svc.cluster.local, IP:10.10.1.2, IP:10.10.1.3
extendedKeyUsage = serverAuth
keyUsage = digitalSignature, keyEncipherment
EOF

openssl x509 -req -in "$OUT/tls.csr" -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" \
  -CAcreateserial -days 30 -out "$OUT/tls.crt" -extfile "$OUT/ext.cnf"

# HAProxy wants one concatenated PEM (leaf + key); nginx wants them separate.
cat "$OUT/tls.crt" "$OUT/tls.key" > "$OUT/haproxy.pem"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create secret generic quic-lab-tls \
  --from-file=tls.crt="$OUT/tls.crt" \
  --from-file=tls.key="$OUT/tls.key" \
  --from-file=haproxy.pem="$OUT/haproxy.pem" \
  --from-file=ca.crt="$OUT/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Copy the CA to the load generator so curl can verify the chain:"
echo "  scp $(pwd)/$OUT/ca.crt node3:/tmp/ca.crt"
openssl x509 -in "$OUT/tls.crt" -noout -subject -ext subjectAltName
