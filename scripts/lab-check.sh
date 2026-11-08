#!/usr/bin/env bash
# Salud del lab. Exit 0 = todo OK
FAIL=0
sec(){ echo; echo "== $* =="; }
ok(){ echo "  ✅ $*"; }
bad(){ echo "  ❌ $*"; FAIL=1; }

sec "Nodo"
kubectl get nodes --no-headers | awk '$2!="Ready"{f=1} END{exit f}' && ok "nodo Ready" || bad "nodo NotReady"

sec "Pods"
P=$(kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"')
[ -z "$P" ] && ok "todos Running/Completed" || { echo "$P"; bad "pods con problemas"; }
P=$(kubectl get pods -A --no-headers | awk '$4=="Running"{split($3,a,"/"); if(a[1]!=a[2]) print}')
[ -z "$P" ] && ok "todos Ready" || { echo "$P"; bad "pods Running pero no Ready"; }

sec "Services sin endpoints"
E=$(kubectl get endpoints -A -o json 2>/dev/null | jq -r '.items[]|select((.subsets//[])|length==0)|.metadata.namespace+"/"+.metadata.name')
[ -z "$E" ] && ok "todos con endpoints" || { echo "$E"; bad "services sin backend"; }

sec "Certificados"
C=$(kubectl get certificate -A --no-headers | awk '$3!="True"')
[ -z "$C" ] && ok "todos Ready" || { echo "$C"; bad "certificados no Ready"; }

sec "ArgoCD Applications"
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  A=$(kubectl get applications.argoproj.io -A --no-headers -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status | awk '$2!="Synced"||$3!="Healthy"')
  [ -z "$A" ] && ok "todas Synced/Healthy" || { echo "$A"; bad "apps con drift o rotas"; }
fi

sec "HTTPS por Ingress (vía Traefik local)"
IP=$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for h in $(kubectl get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' | sort -u); do
  [ -n "$(dig +short "$h" | head -1)" ] || { bad "$h no resuelve en DNS"; continue; }
  r=$(curl -sS -o /dev/null -m 10 --resolve "$h:443:$IP" -w '%{http_code} %{ssl_verify_result}' "https://$h" 2>&1)
  case "$r" in [234]??" 0") ok "$h -> ${r% *} cert válido";; *) bad "$h -> $r";; esac
done

sec "Disco"
FREE=$(df -BG --output=avail /var/lib/rancher | tail -1 | tr -dc 0-9)
[ "$FREE" -ge 20 ] && ok "disco: ${FREE}G libres" || bad "quedan solo ${FREE}G libres"

sec "Backups (Velero)"
if kubectl get crd backups.velero.io >/dev/null 2>&1; then
  L=$(kubectl -n velero get backups -o json | jq -r '[.items[]|select(.status.phase=="Completed")|.status.completionTimestamp]|max // empty')
  if [ -z "$L" ]; then bad "ningún backup completado"; else AGE=$(( ($(date +%s)-$(date -d "$L" +%s))/3600 )); [ "$AGE" -lt 36 ] && ok "último backup hace ${AGE}h" || bad "último backup hace ${AGE}h (más de 36h)"; fi
fi

sec "Métricas (targets)"
R=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/victoriametrics:8428/proxy/api/v1/query?query=%28up%3D%3D0%29" 2>/dev/null)
if [ -z "$R" ]; then bad "VictoriaMetrics no responde"; else
  DOWN=$(jq -r '[.data.result[]?|.metric.job]|unique|join(", ")' <<<"$R")
  [ -z "$DOWN" ] && ok "todos los targets responden" || bad "targets caídos: $DOWN"
fi

echo; [ $FAIL -eq 0 ] && echo "🟢 LAB OK" || echo "🔴 HAY PROBLEMAS"
exit $FAIL
