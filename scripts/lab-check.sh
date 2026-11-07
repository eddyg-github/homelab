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
  r=$(curl -sS -o /dev/null -m 10 --resolve "$h:443:$IP" -w '%{http_code} %{ssl_verify_result}' "https://$h" 2>&1)
  case "$r" in [234]??" 0") ok "$h -> ${r% *} cert válido";; *) bad "$h -> $r";; esac
done

sec "Disco"
U=$(df --output=pcent /var/lib/rancher | tail -1 | tr -dc 0-9)
[ "$U" -lt 85 ] && ok "uso de disco ${U}%" || bad "disco al ${U}%"

echo; [ $FAIL -eq 0 ] && echo "🟢 LAB OK" || echo "🔴 HAY PROBLEMAS"
exit $FAIL
