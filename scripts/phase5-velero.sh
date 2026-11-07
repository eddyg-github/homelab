#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
BK=~/homelab-backup; DISK=/mnt/media4
CN=sealed-secrets-controller; CNS=kube-system
rand(){ head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }
latest(){ curl -sL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'; }
cleanup(){ rm -f /tmp/velero-creds /tmp/velero-all.yaml /tmp/velero.tgz; }
trap cleanup EXIT

echo "== 0) Pre-chequeos =="
kubectl -n $CNS get deploy $CN >/dev/null 2>&1 && ok "Sealed Secrets presente" || { bad "falta Sealed Secrets"; exit 1; }
kubectl -n minio rollout status deploy/minio --timeout=60s >/dev/null 2>&1 && ok "MinIO Ready" || { bad "MinIO no está Ready"; exit 1; }
findmnt -n "$DISK" >/dev/null && ok "$DISK montado" || { bad "$DISK no está montado"; exit 1; }
FREE=$(df -BG --output=avail "$DISK" | tail -1 | tr -dc 0-9)
[ "$FREE" -ge 50 ] && ok "$DISK: ${FREE}G libres" || { bad "$DISK tiene solo ${FREE}G libres"; exit 1; }
[ -s sealed-secrets-pub.crt ] || kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt

echo "== 1) MinIO guarda en $DISK =="
if kubectl -n minio get deploy minio -o json | jq -e '[.spec.template.spec.volumes[]?|select(.name=="data" and .hostPath)]|length>0' >/dev/null; then
  ok "MinIO ya usa un hostPath"
else
  EXTRA=$(kubectl -n minio exec deploy/minio -- sh -c 'for f in /data/* /data/.[!.]*; do [ -e "$f" ] && [ "$f" != /data/.minio.sys ] && echo "$f"; done' 2>/dev/null | head -3)
  [ -z "$EXTRA" ] || { bad "MinIO ya tiene datos ($EXTRA ...). No lo muevo; avisame."; exit 1; }
  python3 - "$DISK" <<'PY'
import yaml,sys
f='apps/minio/deployment-minio.yaml'; o=yaml.safe_load(open(f))
vols=o['spec']['template']['spec']['volumes']
for i,v in enumerate(vols):
    if v['name']=='data': vols[i]={'name':'data','hostPath':{'path':sys.argv[1]+'/minio-data','type':'DirectoryOrCreate'}}
open(f,'w').write(yaml.safe_dump(o,sort_keys=False))
PY
  git add -A; git commit -qm "minio: datos en $DISK/minio-data" ; git push -q && ok "push OK" || { bad "push falló"; exit 1; }
  for i in $(seq 1 24); do
    refresh
    kubectl -n minio get deploy minio -o json | jq -e '[.spec.template.spec.volumes[]?|select(.name=="data" and .hostPath)]|length>0' >/dev/null && break; sleep 15
  done
  kubectl -n minio rollout status deploy/minio --timeout=240s >/dev/null 2>&1 && ok "MinIO Ready sobre $DISK" || { bad "MinIO no levantó con el nuevo volumen"; exit 1; }
fi
ls -d "$DISK/minio-data" >/dev/null 2>&1 && ok "$DISK/minio-data existe" || bad "no veo $DISK/minio-data"

echo "== 2) Bucket 'velero' y usuario con permisos acotados =="
VPASS=$(rand)
kubectl -n minio delete job velero-setup --ignore-not-found >/dev/null
kubectl -n minio create secret generic velero-setup --from-literal=VELERO_PASSWORD="$VPASS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: batch/v1
kind: Job
metadata: {name: velero-setup, namespace: minio}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: minio/mc:RELEASE.2022-10-29T10-09-23Z
          command: ["/bin/sh","-c"]
          env:
            - {name: MINIO_ROOT_USER, valueFrom: {secretKeyRef: {name: minio-env, key: MINIO_ROOT_USER}}}
            - {name: MINIO_ROOT_PASSWORD, valueFrom: {secretKeyRef: {name: minio-env, key: MINIO_ROOT_PASSWORD}}}
            - {name: VELERO_PASSWORD, valueFrom: {secretKeyRef: {name: velero-setup, key: VELERO_PASSWORD}}}
          args:
            - |
              set -e
              mc alias set m http://minio.minio.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
              mc mb --ignore-existing m/velero
              cat > /tmp/p.json <<'J'
              {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::velero","arn:aws:s3:::velero/*"]}]}
              J
              mc admin policy add m velero-rw /tmp/p.json || mc admin policy create m velero-rw /tmp/p.json
              mc admin user add m velero "$VELERO_PASSWORD"
              mc admin policy set m velero-rw user=velero || mc admin policy attach m velero-rw --user velero
              echo "--- buckets:"; mc ls m
              echo "--- usuarios:"; mc admin user list m
YAML
for i in $(seq 1 60); do
  S=$(kubectl -n minio get job velero-setup -o jsonpath='{.status.succeeded}' 2>/dev/null); F=$(kubectl -n minio get job velero-setup -o jsonpath='{.status.failed}' 2>/dev/null)
  [ "${S:-0}" = 1 ] && break; [ "${F:-0}" -ge 1 ] && break; sleep 5
done
echo "--- salida del Job:"; kubectl -n minio logs job/velero-setup 2>&1 | grep -v -i password | tail -12
S=$(kubectl -n minio get job velero-setup -o jsonpath='{.status.succeeded}' 2>/dev/null)
kubectl -n minio delete job velero-setup --ignore-not-found >/dev/null; kubectl -n minio delete secret velero-setup --ignore-not-found >/dev/null
[ "${S:-0}" = 1 ] && ok "bucket y usuario creados" || { bad "el Job falló (ver salida arriba)"; exit 1; }
( umask 077; printf 'Velero (MinIO)  usuario: velero  contraseña: %s  bucket: velero\n' "$VPASS" >> $BK/new-credentials.txt )
ok "contraseña guardada en $BK/new-credentials.txt"

echo "== 3) Velero: CLI y manifiestos =="
VT=$(latest vmware-tanzu/velero); PT=$(latest vmware-tanzu/velero-plugin-for-aws)
[[ "$VT" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$PT" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { bad "versiones inválidas: '$VT' '$PT'"; exit 1; }
echo "   velero $VT, plugin aws $PT"
if ! velero version --client-only 2>/dev/null | grep -q "${VT#v}"; then
  curl -sSL -f -o /tmp/velero.tgz "https://github.com/vmware-tanzu/velero/releases/download/$VT/velero-$VT-linux-amd64.tar.gz" \
   && tar xzf /tmp/velero.tgz -C /tmp "velero-$VT-linux-amd64/velero" && sudo install -m 755 "/tmp/velero-$VT-linux-amd64/velero" /usr/local/bin/velero \
   && rm -rf "/tmp/velero-$VT-linux-amd64" && ok "CLI instalado" || { bad "no pude instalar el CLI de Velero"; exit 1; }
else ok "CLI ya está en $VT"; fi
( umask 077; printf '[default]\naws_access_key_id=velero\naws_secret_access_key=%s\n' "$VPASS" > /tmp/velero-creds )
velero install --namespace velero --provider aws --plugins "velero/velero-plugin-for-aws:$PT" --bucket velero \
  --secret-file /tmp/velero-creds --use-volume-snapshots=false --use-node-agent \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.minio.svc.cluster.local:9000 \
  --dry-run -o yaml > /tmp/velero-all.yaml 2>/tmp/velero-err.txt
grep -q 'CustomResourceDefinition' /tmp/velero-all.yaml && ok "manifiestos generados" || { bad "velero install --dry-run falló:"; head -5 /tmp/velero-err.txt; exit 1; }
mkdir -p platform/velero
python3 - <<'PY'
import yaml
docs=[d for d in yaml.safe_load_all(open('/tmp/velero-all.yaml')) if d]
def clean(o):
    if isinstance(o,dict):
        for k in [k for k,v in o.items() if k=='creationTimestamp' and v is None]: o.pop(k)
        for v in o.values(): clean(v)
    elif isinstance(o,list):
        for v in o: clean(v)
out=[]
for d in docs:
    if d.get('kind')=='Secret': continue
    d.pop('status',None); clean(d)
    if d.get('kind') in ('BackupStorageLocation','VolumeSnapshotLocation'):
        d.setdefault('metadata',{}).setdefault('annotations',{})['argocd.argoproj.io/sync-options']='SkipDryRunOnMissingResource=true'
    out.append(d)
out.append({'apiVersion':'velero.io/v1','kind':'Schedule',
  'metadata':{'name':'daily','namespace':'velero','annotations':{'argocd.argoproj.io/sync-options':'SkipDryRunOnMissingResource=true'}},
  'spec':{'schedule':'30 3 * * *','template':{'includedNamespaces':['media','minio','monitoring','default','argocd','cert-manager','floci'],
          'ttl':'336h0m0s','storageLocation':'default','snapshotVolumes':False}}})
yaml.safe_dump_all(out,open('platform/velero/velero.yaml','w'),sort_keys=False)
print('  recursos:',len(out))
PY
jq -n --rawfile c /tmp/velero-creds '{apiVersion:"v1",kind:"Secret",metadata:{name:"cloud-credentials",namespace:"velero"},type:"Opaque",data:{cloud:($c|@base64)}}' \
  | kubeseal --cert sealed-secrets-pub.crt --format yaml > platform/velero/sealedsecret-cloud-credentials.yaml \
  && ok "credenciales cifradas" || { bad "no pude cifrar las credenciales"; exit 1; }

echo "== 4) Qué volúmenes respalda Velero (opt-in) =="
python3 - <<'PY'
import yaml
for n,vol in (('jellyfin','jellyfin-config'),('sonarr','config'),('radarr','config'),('prowlarr','config'),('qbittorrent','config')):
    f=f'apps/media/deployment-{n}.yaml'; o=yaml.safe_load(open(f))
    m=o['spec']['template'].setdefault('metadata',{}).setdefault('annotations',{})
    m['backup.velero.io/backup-volumes']=vol; open(f,'w').write(yaml.safe_dump(o,sort_keys=False)); print('  ',n,'->',vol)
PY

echo "== 5) Chequeo de fugas y push =="
LEAK=0; grep -rqF --exclude-dir=.git -- "$VPASS" . && { bad "la contraseña de velero aparece en claro"; LEAK=1; }
[ $LEAK = 0 ] && ok "sin credenciales en claro" || exit 1
cat > docs/BACKUPS.md <<'MD'
# Backups (Velero + MinIO)
- Destino: bucket `velero` en MinIO, datos en `/mnt/media4/minio-data` (disco distinto al del sistema).
- Programación: `daily` a las 03:30, retención 14 días. Respalda `/config` de Jellyfin, Sonarr, Radarr, Prowlarr y qBittorrent (opt-in por anotación `backup.velero.io/backup-volumes`).
- No respalda: la media, la caché de Jellyfin, MinIO en sí ni los datos de VictoriaMetrics.
- Backup manual: `velero backup create manual-$(date +%F) --from-schedule daily --wait`
- Listar: `velero backup get`. Restaurar: `velero restore create --from-backup <nombre> --wait`
- Cluster nuevo: restaurar clave de Sealed Secrets, ArgoCD, apps; luego `velero restore create --from-backup <ultimo>`.
- Limitación: MinIO vive en el mismo servidor; no cubre pérdida del equipo. Copiar el bucket fuera del servidor es un paso pendiente.
MD
git add -A; git commit -qm "velero: backups a MinIO ($DISK), schedule diario, opt-in de volumenes /config"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh

echo "== 6) Esperando a Velero (máx 8 min) =="
for i in $(seq 1 48); do kubectl -n velero get deploy velero >/dev/null 2>&1 && break; refresh; sleep 10; done
kubectl -n velero rollout status deploy/velero --timeout=240s >/dev/null 2>&1 && ok "velero Ready" || { bad "velero no está Ready"; kubectl -n velero get pods; kubectl -n argocd get application platform-velero 2>&1; exit 1; }
kubectl -n velero rollout status ds/node-agent --timeout=240s >/dev/null 2>&1 && ok "node-agent Ready" || bad "node-agent no está Ready"
for i in $(seq 1 24); do P=$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null); [ "$P" = Available ] && break; sleep 10; done
[ "$P" = Available ] && ok "almacenamiento de backups: Available" || { bad "BSL en estado '$P'"; kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.message}{"\n"}'; exit 1; }
for n in jellyfin sonarr radarr prowlarr qbittorrent; do kubectl -n media rollout status deploy/$n --timeout=240s >/dev/null 2>&1 && ok "$n Ready" || bad "$n no Ready"; done

echo "== 7) Prueba real: backup -> borrar -> restaurar =="
kubectl delete ns velero-test --ignore-not-found --wait=true >/dev/null 2>&1
kubectl create ns velero-test >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data-test, namespace: velero-test}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 100Mi}}}
---
apiVersion: v1
kind: Pod
metadata:
  name: tester
  namespace: velero-test
  annotations: {backup.velero.io/backup-volumes: data}
spec:
  containers:
    - name: t
      image: busybox:1.36
      command: ["sh","-c","echo prueba-$(date +%s) > /data/proof.txt; sleep 3600"]
      volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: data-test}}]
YAML
kubectl -n velero-test wait --for=condition=Ready pod/tester --timeout=180s >/dev/null 2>&1 && ok "pod de prueba listo" || { bad "el pod de prueba no arrancó"; exit 1; }
PROOF=$(kubectl -n velero-test exec tester -- cat /data/proof.txt); echo "   contenido original: $PROOF"
BN=vtest-$(date +%H%M%S)
velero backup create $BN --include-namespaces velero-test --wait >/dev/null 2>&1
[ "$(kubectl -n velero get backup $BN -o jsonpath='{.status.phase}')" = Completed ] && ok "backup $BN Completed" || { bad "backup no completó"; velero backup describe $BN --details 2>&1 | tail -15; exit 1; }
kubectl -n velero get podvolumebackups -l velero.io/backup-name=$BN --no-headers 2>/dev/null | grep -q Completed && ok "datos del volumen respaldados (kopia)" || bad "no veo PodVolumeBackup completado"
kubectl delete ns velero-test --wait=true --timeout=180s >/dev/null 2>&1 && ok "namespace de prueba borrado"
velero restore create $BN-r --from-backup $BN --wait >/dev/null 2>&1
[ "$(kubectl -n velero get restore $BN-r -o jsonpath='{.status.phase}')" = Completed ] && ok "restore Completed" || { bad "restore no completó"; velero restore describe $BN-r --details 2>&1 | tail -15; }
kubectl -n velero-test wait --for=condition=Ready pod/tester --timeout=240s >/dev/null 2>&1
GOT=$(kubectl -n velero-test exec tester -- cat /data/proof.txt 2>/dev/null); echo "   contenido restaurado: $GOT"
[ -n "$PROOF" ] && [ "$PROOF" = "$GOT" ] && ok "RESTAURACIÓN VERIFICADA: el dato volvió idéntico" || bad "el dato restaurado no coincide"
kubectl delete ns velero-test --ignore-not-found >/dev/null 2>&1; velero backup delete $BN --confirm >/dev/null 2>&1

echo "== 8) Primer backup completo con el schedule =="
for i in $(seq 1 12); do kubectl -n velero get schedule daily >/dev/null 2>&1 && break; refresh; sleep 10; done
FB=first-full-$(date +%m%d-%H%M)
velero backup create $FB --from-schedule daily --wait >/dev/null 2>&1
PH=$(kubectl -n velero get backup $FB -o jsonpath='{.status.phase}')
[ "$PH" = Completed ] && ok "$FB Completed" || { bad "$FB terminó en '$PH'"; velero backup describe $FB --details 2>&1 | grep -i -E 'error|warn|fail' | head -10; }
kubectl -n velero get podvolumebackups -l velero.io/backup-name=$FB --no-headers 2>/dev/null | awk '{print "   volumen:",$0}' | cut -c1-110
velero backup get

echo "== 9) lab-check vigila los backups =="
if ! grep -q 'Backups (Velero)' scripts/lab-check.sh; then
python3 - <<'PY'
import os
p=os.path.expanduser('~/homelab/scripts/lab-check.sh'); s=open(p).read()
blk='''sec "Backups (Velero)"
if kubectl get crd backups.velero.io >/dev/null 2>&1; then
  L=$(kubectl -n velero get backups -o json | jq -r '[.items[]|select(.status.phase=="Completed")|.status.completionTimestamp]|max // empty')
  if [ -z "$L" ]; then bad "ningún backup completado"; else AGE=$(( ($(date +%s)-$(date -d "$L" +%s))/3600 )); [ "$AGE" -lt 36 ] && ok "último backup hace ${AGE}h" || bad "último backup hace ${AGE}h (más de 36h)"; fi
fi

'''
i=s.index('echo; [ $FAIL'); open(p,'w').write(s[:i]+blk+s[i:])
PY
fi
git add -A; git diff --cached --quiet || git commit -qm "lab-check: vigila backups de Velero"; git push -q && ok "push OK"
kubectl -n argocd get applications.argoproj.io
