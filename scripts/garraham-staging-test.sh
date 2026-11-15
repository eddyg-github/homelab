#!/usr/bin/env bash
set -uo pipefail
EMAIL=$(kubectl get clusterissuer letsencrypt -o jsonpath='{.spec.acme.email}')
[ -n "$EMAIL" ] || { echo "❌ no pude leer el email del issuer"; exit 1; }
kubectl apply -f - <<Y
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: letsencrypt-staging}
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef: {name: letsencrypt-staging-key}
    solvers: [{http01: {ingress: {ingressClassName: traefik}}}]
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: garraham-staging-test, namespace: garraham}
spec:
  secretName: garraham-staging-test-tls
  dnsNames: [garraham.lyxar.dedyn.io]
  issuerRef: {name: letsencrypt-staging, kind: ClusterIssuer}
Y
for i in $(seq 1 24); do
  S=$(kubectl -n garraham get certificate garraham-staging-test -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  [ "$S" = True ] && break; sleep 10
done
echo "== Resultado =="
kubectl -n garraham get certificate garraham-staging-test
kubectl -n garraham get challenge,order 2>&1 | grep -v planigrafo
kubectl -n garraham describe challenge 2>/dev/null | grep -E 'Reason|State' | head -4 | cut -c1-250
