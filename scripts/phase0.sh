#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
BK=~/homelab-backup/$(date +%F-%H%M); mkdir -p "$BK"; chmod 700 ~/homelab-backup "$BK"

echo "== Backup de manifiestos =="
for r in ns nodes pv pvc sc deploy sts ds cronjob svc ingress cm \
  certificates.cert-manager.io certificaterequests.cert-manager.io issuers.cert-manager.io \
  clusterissuers.cert-manager.io middlewares.traefik.io applications.argoproj.io \
  helmchartconfigs.helm.cattle.io; do
  kubectl get "$r" -A -o yaml > "$BK/${r%%.*}.yaml" 2>/dev/null
done
(umask 077; kubectl get secrets -A -o yaml > "$BK/SECRETS-NO-SUBIR.yaml")
[ -s "$BK/deploy.yaml" ] && ok "manifiestos en $BK" || bad "backup de manifiestos falló"

echo "== Backup de la DB de k3s (copia en caliente, red de seguridad) =="
sudo tar czf "$BK/k3s-server.tgz" -C /var/lib/rancher/k3s server/db server/token server/tls 2>/dev/null \
  && sudo chown "$USER" "$BK/k3s-server.tgz" && chmod 600 "$BK/k3s-server.tgz" && ok "k3s-server.tgz" || bad "no pude copiar /var/lib/rancher/k3s/server"

echo "== Backup de datos de PVC (sin media, cache ni VictoriaMetrics) =="
sudo find /var/lib/rancher/k3s/storage -maxdepth 1 -name 'pvc-*' | while read -r d; do
  case "$d" in *media-pvc*|*jellyfin-cache*|*victoriametrics-data*) continue;; esac
  sudo tar czf "$BK/data-$(basename "$d").tgz" -C "$d" . && sudo chown "$USER" "$BK/data-$(basename "$d").tgz" && ok "$(basename "$d")"
done

echo "== Diagnóstico para pegar =="
{
 echo "### DE DÓNDE SALEN LOS DATOS (PVC/hostPath/emptyDir)"
 kubectl get pods -A -o json | jq -r '.items[]|.metadata.namespace as $n|.metadata.name as $p|(.spec.volumes//[])[]|select(.persistentVolumeClaim or .hostPath or .emptyDir)|[$n,$p,(if .persistentVolumeClaim then "PVC:"+.persistentVolumeClaim.claimName elif .hostPath then "HOSTPATH:"+.hostPath.path else "EMPTYDIR" end)]|@tsv' | grep -v -E 'kube-api-access|^kube-system|cattle|fleet' 
 echo; echo "### DISCO/RAM"; lsblk -o NAME,ROTA,SIZE,TYPE,MOUNTPOINT; df -h / /var/lib/rancher; free -h
 echo; echo "### CERT GRAFANA"; kubectl -n monitoring describe certificate grafana-tls | tail -25
 kubectl get challenges,orders -A
 echo; echo "### CLUSTERISSUER"; kubectl get clusterissuer letsencrypt -o yaml | grep -v -E 'uid|resourceVersion|creationTimestamp'
 echo; echo "### TRAEFIK CONFIG"; kubectl -n kube-system get helmchartconfig traefik -o yaml 2>&1 | head -40
 echo; echo "### VICTORIAMETRICS"; kubectl -n monitoring get sts victoriametrics -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}{.spec.template.spec.containers[0].image}{"\n"}'
 echo; echo "### CONFIGMAPS monitoring"; kubectl -n monitoring get cm -o yaml | grep -v -E 'uid|resourceVersion|creationTimestamp'
 echo; echo "### DNS"; for h in lyxar.dedyn.io grafana.lyxar.dedyn.io argocd.lyxar.dedyn.io test.lyxar.dedyn.io; do echo "$h -> $(dig +short $h | tr '\n' ' ')"; done
 echo; echo "### IP PÚBLICA"; curl -s -m 5 https://ifconfig.me; echo
} > "$BK/PEGAR-ESTO.txt" 2>&1
ok "diagnóstico en $BK/PEGAR-ESTO.txt"
echo; echo ">>> Revisá que PEGAR-ESTO.txt no tenga tokens/contraseñas y pegámelo: cat $BK/PEGAR-ESTO.txt"
