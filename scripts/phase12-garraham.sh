#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
GH=eddyg-github; export REG=ghcr.io/$GH; export TAG=$(date +%F)-1; A=apps/garraham
CN=sealed-secrets-controller; CNS=kube-system
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  kubectl -n argocd annotate applicationset apps argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1; }

echo "== 0) Pre-chequeos =="
for i in planigrafo-backend planigrafo-frontend; do docker image inspect $i:latest >/dev/null 2>&1 && ok "imagen local $i" || { bad "falta la imagen local $i:latest"; exit 1; }; done
kubectl -n garraham get secret planigrafo-secrets >/dev/null 2>&1 && ok "planigrafo-secrets existe" || { bad "falta planigrafo-secrets"; exit 1; }
[ -s sealed-secrets-pub.crt ] || kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt
CERT_UID=$(kubectl -n garraham get certificate planigrafo-tls-secret -o jsonpath='{.metadata.uid}')
ING_UID=$(kubectl -n garraham get ingress planigrafo-ingress -o jsonpath='{.metadata.uid}')
[ -n "$CERT_UID" ] && [ -n "$ING_UID" ] && ok "UID del Certificate e Ingress anotados (para verificar que no se recrean)" || { bad "no encontré el Certificate o el Ingress"; exit 1; }

echo "== 1) Subir imágenes a GHCR (privadas) =="
read -rsp "   Token GitHub con write:packages: " PT; echo
echo "$PT" | docker login ghcr.io -u $GH --password-stdin >/dev/null 2>&1 && ok "login en ghcr.io" || { bad "login falló (token incorrecto o sin permiso)"; exit 1; }
unset PT
for i in backend frontend; do
  docker tag planigrafo-$i:latest $REG/planigrafo-$i:$TAG
  docker push $REG/planigrafo-$i:$TAG >/tmp/push-$i.txt 2>&1 && ok "subida $REG/planigrafo-$i:$TAG" || { tail -3 /tmp/push-$i.txt; bad "falló el push de $i"; docker logout ghcr.io >/dev/null; exit 1; }
done
docker logout ghcr.io >/dev/null 2>&1
echo "   >>> Verificá en https://github.com/$GH?tab=packages que ambos paquetes figuren como PRIVATE."

echo "== 2) Secretos =="
read -rsp "   Token GitHub con read:packages (puede ser el mismo): " RT; echo
U=$GH P="$RT" jq -n '{apiVersion:"v1",kind:"Secret",metadata:{name:"ghcr-pull",namespace:"garraham"},type:"kubernetes.io/dockerconfigjson",
  data:{".dockerconfigjson":({auths:{"ghcr.io":{username:env.U,password:env.P,auth:((env.U+":"+env.P)|@base64)}}}|tojson|@base64)}}' > /tmp/ghcr-secret.json
kubectl apply -f /tmp/ghcr-pull-secret.json >/dev/null 2>&1 || kubectl apply -f /tmp/ghcr-secret.json >/dev/null && ok "ghcr-pull creado en el cluster"
mkdir -p $A
kubeseal --cert sealed-secrets-pub.crt --format yaml < /tmp/ghcr-secret.json > $A/sealedsecret-ghcr-pull.yaml && [ -s $A/sealedsecret-ghcr-pull.yaml ] && ok "ghcr-pull cifrado" || { bad "no pude cifrar ghcr-pull"; exit 1; }
rm -f /tmp/ghcr-secret.json; unset RT
H0=$(kubectl -n garraham get secret planigrafo-secrets -o json | jq -S .data | sha256sum | cut -c1-16)
kubectl -n garraham annotate secret planigrafo-secrets sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null
kubectl -n garraham annotate secret ghcr-pull sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null
kubectl -n garraham get secret planigrafo-secrets -o json | jq '{apiVersion:"v1",kind:"Secret",metadata:{name:.metadata.name,namespace:.metadata.namespace},type:(.type//"Opaque"),data:.data}' \
  | kubeseal --cert sealed-secrets-pub.crt --format yaml > $A/sealedsecret-planigrafo-secrets.yaml && [ -s $A/sealedsecret-planigrafo-secrets.yaml ] && ok "planigrafo-secrets cifrado" || { bad "no pude cifrar planigrafo-secrets"; exit 1; }

echo "== 3) Exporto manifiestos a $A =="
python3 - <<'PY' || { echo "  ❌ falló la exportación"; exit 1; }
import subprocess,json,yaml,os,re
os.chdir(os.path.expanduser('~/homelab')); A='apps/garraham/'; REG=os.environ['REG']; TAG=os.environ['TAG']
def get(k,n): return json.loads(subprocess.check_output(['kubectl','-n','garraham','get',k,n,'-o','json']))
RX=re.compile(r'(field\.)?cattle\.io/|kubectl\.kubernetes\.io/(last-applied|restartedAt)|deployment\.kubernetes\.io|pv\.kubernetes\.io|volume\.(beta\.)?kubernetes\.io')
def clean(o):
    o.pop('status',None); m=o['metadata']
    for k in ('uid','resourceVersion','generation','creationTimestamp','managedFields','ownerReferences','selfLink','finalizers'): m.pop(k,None)
    a=m.get('annotations',{})
    for k in list(a):
        if RX.match(k): del a[k]
    if not a: m.pop('annotations',None)
    sp=o.get('spec',{})
    if o['kind']=='Service':
        for k in ('clusterIP','clusterIPs','ipFamilies','ipFamilyPolicy','internalTrafficPolicy','sessionAffinity'): sp.pop(k,None)
    if o['kind']=='PersistentVolumeClaim': sp.pop('volumeName',None)
    ta=sp.get('template',{}).get('metadata',{}).get('annotations',{})
    for k in list(ta):
        if RX.match(k): del ta[k]
    if 'template' in sp and not ta: sp['template']['metadata'].pop('annotations',None)
    return o
items=[('deployment','backend'),('deployment','frontend'),('deployment','mysql'),('service','backend-service'),('service','frontend-service'),('service','mysql-service'),
       ('persistentvolumeclaim','mysql-data-v2'),('persistentvolumeclaim','mysql-backup'),('cronjob','mysql-backup'),('ingress','planigrafo-ingress')]
for k,n in items:
    o=clean(get(k,n))
    if k=='deployment' and n in ('backend','frontend'):
        s=o['spec']['template']['spec']; c=s['containers'][0]
        c['image']=f'{REG}/planigrafo-{n}:{TAG}'; c['imagePullPolicy']='IfNotPresent'; s['imagePullSecrets']=[{'name':'ghcr-pull'}]
    yaml.safe_dump(o,open(f'{A}{k}-{n}.yaml','w'),sort_keys=False,width=200)
yaml.safe_dump({'apiVersion':'v1','kind':'Namespace','metadata':{'name':'garraham'}},open(A+'namespace.yaml','w'),sort_keys=False)
holder='''apiVersion: apps/v1
kind: Deployment
metadata: {name: mysql-backup-holder, namespace: garraham}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: mysql-backup-holder}}
  template:
    metadata:
      labels: {app: mysql-backup-holder}
      annotations: {backup.velero.io/backup-volumes: backup}
    spec:
      containers:
        - name: holder
          image: busybox:1.36
          command: [sh, -c, "while true; do sleep 3600; done"]
          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {memory: 32Mi}}
          volumeMounts: [{name: backup, mountPath: /backup}]
      volumes: [{name: backup, persistentVolumeClaim: {claimName: mysql-backup}}]
'''
open(A+'deployment-mysql-backup-holder.yaml','w').write(holder)
p='platform/velero/velero.yaml'; docs=[d for d in yaml.safe_load_all(open(p)) if d]
for d in docs:
    if d.get('kind')=='Schedule':
        ns=d['spec']['template']['includedNamespaces']
        if 'garraham' not in ns: ns.append('garraham')
yaml.safe_dump_all(docs,open(p,'w'),sort_keys=False)
PY
ok "manifiestos exportados"
mkdir -p docs
cat > docs/GARRAHAM.md <<'MD'
# Planígrafo (garraham)
- Manifiestos en `apps/garraham/`. Imágenes privadas: `ghcr.io/eddyg-github/planigrafo-{backend,frontend}:<fecha>-N` (secret `ghcr-pull`).
- Cambiar la app: construir la imagen con tag NUEVO, subirla a GHCR, editar el tag en `apps/garraham/deployment-*.yaml`, git push. NO tocar el Ingress ni el Certificate (límite de Let's Encrypt: 5 por semana por dominio).
- Backup: CronJob `mysql-backup` (03:00) escribe en el PVC `mysql-backup`, que Velero respalda (holder). Los datos vivos de MariaDB no se respaldan.
MD

echo "== 4) Chequeo de fugas, dry-run y push =="
LEAK=0
for k in $(kubectl -n garraham get secret planigrafo-secrets -o json | jq -r '.data|keys[]'); do
  v=$(kubectl -n garraham get secret planigrafo-secrets -o json | jq -r --arg k $k '.data[$k]|@base64d'); [ ${#v} -ge 8 ] && grep -rqF --exclude-dir=.git -- "$v" . && { bad "valor de $k en claro en el repo"; LEAK=1; }
done
[ $LEAK = 0 ] && ok "sin secretos en claro" || exit 1
kubectl apply --dry-run=server -f $A/ >/tmp/dry12.txt 2>&1 && ok "manifiestos válidos" || { head -12 /tmp/dry12.txt; bad "dry-run falló, no se publica"; exit 1; }
git add -A; git diff --cached --quiet || git commit -qm "garraham: a Git, imagenes en GHCR privado, secretos cifrados, velero"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh

echo "== 5) Esperando (máx 8 min) =="
for i in $(seq 1 48); do kubectl -n garraham get deploy mysql-backup-holder >/dev/null 2>&1 && break; refresh; sleep 10; done
for d in backend frontend mysql; do kubectl -n garraham rollout status deploy/$d --timeout=300s >/dev/null 2>&1 && ok "$d Ready" || { bad "$d no Ready"; kubectl -n garraham get pods; kubectl -n garraham describe pod -l app=$d | grep -E 'Failed|ErrImage|Back-off' | head -3; }; done
echo "   imágenes en uso:"; kubectl -n garraham get deploy -o json | jq -r '.items[]|"     \(.metadata.name): \(.spec.template.spec.containers[0].image)"'

echo "== 6) El certificado NO se tocó =="
[ "$(kubectl -n garraham get certificate planigrafo-tls-secret -o jsonpath='{.metadata.uid}')" = "$CERT_UID" ] && ok "Certificate con el mismo UID" || bad "el Certificate fue RECREADO"
[ "$(kubectl -n garraham get ingress planigrafo-ingress -o jsonpath='{.metadata.uid}')" = "$ING_UID" ] && ok "Ingress con el mismo UID" || bad "el Ingress fue RECREADO"
[ "$H0" = "$(kubectl -n garraham get secret planigrafo-secrets -o json | jq -S .data | sha256sum | cut -c1-16)" ] && ok "planigrafo-secrets sin cambios" || bad "planigrafo-secrets cambió"
kubectl -n garraham get certificate planigrafo-tls-secret
kubectl -n argocd get applications.argoproj.io app-garraham --no-headers
