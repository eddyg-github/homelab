#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
BK=$(ls -dt ~/homelab-backup/*/ | head -1); BK=${BK%/}
STG=/var/lib/rancher/k3s/storage
SENS='PASSWORD|SECRET|TOKEN|_KEY$|_USER$'

sel(){ kubectl -n "$1" get deploy "$2" -o json | jq -r '.spec.selector.matchLabels|to_entries|map("\(.key)=\(.value)")|join(",")'; }

persist(){ # ns deploy pvc size vol mountpath memReq memLim mode(exec|emptydir)
  local ns=$1 d=$2 pvc=$3 size=$4 vol=$5 mp=$6 mr=$7 ml=$8 mode=$9
  local tgz="$BK/data-$d-$(date +%H%M%S).tgz" dir s pu
  if kubectl -n "$ns" get deploy "$d" -o json | jq -e --arg p "$pvc" '[.spec.template.spec.volumes[]?|select(.persistentVolumeClaim.claimName==$p)]|length>0' >/dev/null; then
    ok "$ns/$d ya usa $pvc"; return 0; fi
  echo "-- $ns/$d"
  if [ "$mode" = exec ]; then
    kubectl -n "$ns" exec deploy/"$d" -- tar cf - -C "$mp" . 2>/dev/null | gzip > "$tgz"
    [ "$(tar tzf "$tgz" 2>/dev/null | wc -l)" -ge 2 ] || { bad "backup vacío o fallido de $mp en $d: no lo toco"; return 1; }
  else
    pu=$(kubectl -n "$ns" get pods -o jsonpath='{.items[0].metadata.uid}')
    sudo tar czpf "$tgz" -C "/var/lib/kubelet/pods/$pu/volumes/kubernetes.io~empty-dir/$vol" . 2>/dev/null; sudo chown "$USER" "$tgz"
    tar tzf "$tgz" >/dev/null 2>&1 || { bad "no pude respaldar el emptyDir de $d: no lo toco"; return 1; }
  fi
  chmod 600 "$tgz"; ok "backup $(basename "$tgz") ($(du -h "$tgz" | cut -f1))"

  printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  accessModes: [ReadWriteOnce]\n  storageClassName: local-path\n  resources:\n    requests:\n      storage: %s\n' "$pvc" "$ns" "$size" | kubectl apply -f - >/dev/null
  kubectl -n "$ns" get deploy "$d" -o json | jq --arg vn "$vol" --arg pvc "$pvc" --arg mp "$mp" --arg mr "$mr" --arg ml "$ml" '
    .spec.strategy={type:"Recreate"}
    | .spec.template.spec.volumes=([(.spec.template.spec.volumes//[])[]|select(.name!=$vn)]+[{name:$vn,persistentVolumeClaim:{claimName:$pvc}}])
    | .spec.template.spec.containers[0].volumeMounts=([(.spec.template.spec.containers[0].volumeMounts//[])[]|select(.name!=$vn)]+[{name:$vn,mountPath:$mp}])
    | if ((.spec.template.spec.containers[0].resources//{})|length)==0 then .spec.template.spec.containers[0].resources={requests:{cpu:"20m",memory:$mr},limits:{memory:$ml}} else . end' \
    | kubectl replace -f - >/dev/null || { bad "no pude parchear $d"; return 1; }

  kubectl -n "$ns" rollout status deploy/"$d" --timeout=240s >/dev/null 2>&1 || { bad "$d no levantó con el PVC nuevo"; return 1; }
  s=$(sel "$ns" "$d")
  kubectl -n "$ns" scale deploy/"$d" --replicas=0 >/dev/null
  for i in $(seq 1 40); do [ -z "$(kubectl -n "$ns" get pods -l "$s" -o name 2>/dev/null)" ] && break; sleep 2; done
  dir="$STG/$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')_${ns}_${pvc}"
  if sudo test -d "$dir"; then sudo tar xzpf "$tgz" -C "$dir" 2>/dev/null; ok "datos restaurados en el PVC $pvc"
  else bad "no encuentro $dir. Restaurá a mano desde $tgz"; fi
  kubectl -n "$ns" scale deploy/"$d" --replicas=1 >/dev/null
  kubectl -n "$ns" rollout status deploy/"$d" --timeout=240s >/dev/null 2>&1 && ok "$ns/$d Ready con $pvc" || bad "$ns/$d no quedó Ready"
}

secretize(){ # ns deploy
  local ns=$1 d=$2 sn=$2-env J
  J=$(kubectl -n "$ns" get deploy "$d" -o json)
  if [ "$(jq --arg re "$SENS" '[.spec.template.spec.containers[0].env[]?|select(.value!=null and (.name|test($re)))]|length' <<<"$J")" = 0 ]; then
    ok "$ns/$d: sin credenciales en claro"; return; fi
  jq --arg n "$sn" --arg ns "$ns" --arg re "$SENS" '{apiVersion:"v1",kind:"Secret",metadata:{name:$n,namespace:$ns},type:"Opaque",stringData:([.spec.template.spec.containers[0].env[]?|select(.value!=null and (.name|test($re)))|{(.name):.value}]|add)}' <<<"$J" \
    | kubectl apply -f - >/dev/null || { bad "no pude crear el Secret de $d"; return 1; }
  jq --arg n "$sn" --arg re "$SENS" '.spec.template.spec.containers[0].env|=map(if (.value!=null and (.name|test($re))) then {name:.name,valueFrom:{secretKeyRef:{name:$n,key:.name}}} else . end)' <<<"$J" \
    | kubectl replace -f - >/dev/null && ok "$ns/$d: credenciales movidas al Secret $sn" || bad "no pude actualizar $d"
}

echo "== 1) Persistencia (backup -> PVC -> restore) =="
persist media prowlarr    prowlarr-config    1Gi config /config 128Mi 512Mi exec
persist media sonarr      sonarr-config      2Gi config /config 128Mi 1Gi   exec
persist media radarr      radarr-config      2Gi config /config 128Mi 1Gi   exec
persist media qbittorrent qbittorrent-config 1Gi config /config 128Mi 1Gi   exec
persist minio minio       minio-data        20Gi data   /data   128Mi 1Gi   emptydir

echo "== 2) Credenciales fuera de los Deployments =="
secretize minio minio
secretize monitoring grafana

echo "== 3) Filebrowser: de / a /mnt/unified-media =="
kubectl -n default get deploy filebrowser -o json | jq '
  (.spec.template.spec.volumes[]|select(.name=="root")|.hostPath.path)="/mnt/unified-media"
  | .spec.strategy={type:"Recreate"}
  | .spec.template.spec.containers[0].resources={requests:{cpu:"10m",memory:"64Mi"},limits:{memory:"256Mi"}}' \
  | kubectl replace -f - >/dev/null && ok "filebrowser acotado" || bad "no pude parchear filebrowser"

echo "== 4) Verificación =="
for x in media/prowlarr media/sonarr media/radarr media/qbittorrent minio/minio monitoring/grafana default/filebrowser; do
  kubectl -n "${x%/*}" rollout status deploy/"${x#*/}" --timeout=240s >/dev/null 2>&1 && ok "$x Ready" || bad "$x NO Ready"
done
kubectl get pvc -A | grep -E 'NAME|-config|minio-data'
echo "  /config de sonarr: $(kubectl -n media exec deploy/sonarr -- ls /config 2>/dev/null | tr '\n' ' ')"
echo "  /data de minio:    $(kubectl -n minio exec deploy/minio -- ls -a /data 2>/dev/null | tr '\n' ' ')"
