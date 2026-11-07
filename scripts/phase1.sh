#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }

echo "== 1) ArgoCD repo-server =="
kubectl -n argocd get pods --no-headers | awk '$3=="Unknown"||$3=="Terminating"{print $1}' \
  | xargs -r kubectl -n argocd delete pod --force --grace-period=0
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s >/dev/null 2>&1 \
  && ok "repo-server Ready" || bad "repo-server sigue caído: kubectl -n argocd describe pod -l app.kubernetes.io/name=argocd-repo-server"

echo "== 2) Certificado de Grafana =="
kubectl -n monitoring get challenges,orders 2>&1 | head -5
kubectl -n monitoring delete challenges,orders,certificaterequests --all --wait=false >/dev/null 2>&1
kubectl -n monitoring delete pod,svc,ingress -l acme.cert-manager.io/http01-solver=true --ignore-not-found >/dev/null 2>&1
kubectl -n monitoring wait --for=condition=Ready certificate/grafana-tls --timeout=240s >/dev/null 2>&1 \
  && ok "grafana-tls Ready" \
  || { bad "grafana-tls sigue sin emitir (la Fase 4 lo resuelve de raíz). Causa:"; kubectl -n monitoring get challenges -o jsonpath='{range .items[*]}{.status.reason}{"\n"}{end}'; }

echo "== 3) PVs en Retain (no perder datos si se borra un PVC) =="
for pv in $(kubectl get pv -o name); do
  kubectl patch "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
done
[ -z "$(kubectl get pv --no-headers | awk '$4!="Retain"')" ] && ok "todos los PV en Retain" || bad "algún PV sigue en Delete"
