#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
echo "== 0) Estado previo =="
B=$(kubectl -n argocd get applications.argoproj.io --no-headers | awk '$2!="Synced"||$3!="Healthy"')
[ -z "$B" ] && ok "todas las apps Synced/Healthy" || { echo "$B"; bad "hay apps no sanas: no sigo"; exit 1; }
ls ~/homelab-backup/rancher-* >/dev/null 2>&1 && ok "backup de recursos de Rancher presente" || { bad "falta el backup de Rancher"; exit 1; }
echo "   RAM de cattle/fleet antes: $(kubectl top pods -A --no-headers | awk '$1 ~ /cattle|fleet/ {s+=$4} END {print s}') MiB"
read -r -p ">>> Se va a BORRAR Rancher, Fleet, Turtles y CAPI. Escribí SI para continuar: " A
[ "${A:-}" = SI ] || { bad "cancelado"; exit 1; }

echo "== 1) helm uninstall =="
for r in rancher-turtles:cattle-turtles-system fleet-agent-local:cattle-fleet-local-system fleet:cattle-fleet-system rancher:cattle-system rancher-webhook:cattle-system system-upgrade-controller:cattle-system fleet-crd:cattle-fleet-system; do
  helm uninstall "${r%%:*}" -n "${r##*:}" --timeout 120s >/dev/null 2>&1 && ok "${r%%:*}" || echo "   (aviso) ${r%%:*}: no se pudo o ya no estaba"
done
echo "== 2) Webhooks de Rancher que podrían bloquear =="
for k in validatingwebhookconfiguration mutatingwebhookconfiguration; do
  for w in $(kubectl get $k -o name 2>/dev/null | grep -i -E 'cattle|rancher|fleet|capi|turtles'); do kubectl delete $w >/dev/null 2>&1 && echo "   borrado $w"; done
done
echo "== 3) Namespaces =="
NS=$(kubectl get ns -o name | sed 's#namespace/##' | grep -E '^(cattle-|fleet-|cluster-fleet-|local$|p-|user-)')
echo "$NS" | tr '\n' ' '; echo
for n in $NS; do kubectl delete ns $n --wait=false >/dev/null 2>&1; done
sleep 60
for n in $(kubectl get ns --no-headers | awk '$2=="Terminating"{print $1}' | grep -E '^(cattle-|fleet-|cluster-fleet-|local$|p-|user-)'); do
  echo "   forzando finalizers de $n"
  kubectl get ns $n -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/$n/finalize" -f - >/dev/null 2>&1
done
echo "== 4) CRDs de Rancher (se conservan helm.cattle.io y k3s.cattle.io) =="
CR=$(kubectl get crd -o name | sed 's#.*/##' | grep -E '\.(management|fleet|catalog|provisioning|rke|ui|auditlog|telemetry|upgrade|turtles-capi)\.cattle\.io$|rke-machine(-config)?\.cattle\.io$|cluster\.x-k8s\.io$')
echo "$CR" | wc -l | xargs echo "   CRDs a borrar:"
for c in $CR; do kubectl delete crd $c --wait=false >/dev/null 2>&1; done
sleep 45
REST=$(kubectl get crd -o name | sed 's#.*/##' | grep -E 'cattle\.io$|x-k8s\.io$' | grep -v -E 'helm\.cattle\.io|k3s\.cattle\.io')
[ -z "$REST" ] && ok "CRDs de Rancher borrados" || { echo "$REST" | sed 's/^/   queda: /'; }
echo "== 5) Verificación =="
sleep 20
kubectl get ns | grep -E 'cattle|fleet' || ok "sin namespaces de Rancher"
kubectl get crd | grep -E 'helmcharts.helm.cattle.io|traefik.io' | awk '{print "   conservado:",$1}' | head -3
for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
sleep 40
kubectl -n argocd get applications.argoproj.io --no-headers | awk '{print "  ",$1,$2,$3}'
kubectl get nodes --no-headers
kubectl top nodes
