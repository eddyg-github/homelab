#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
IP=192.168.1.47
DOM=lyxar.dedyn.io

echo "== 1) Traefik: IP real de los clientes + access log =="
mkdir -p platform/traefik
cat > platform/traefik/helmchartconfig.yaml <<'YAML'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      spec:
        externalTrafficPolicy: Local
    logs:
      access:
        enabled: true
        format: json
YAML
kubectl apply -f platform/traefik/helmchartconfig.yaml >/dev/null
for i in $(seq 1 40); do [ "$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}')" = Local ] && break; sleep 5; done
kubectl -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null 2>&1
sleep 10
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve jellyfin.$DOM:443:$IP https://jellyfin.$DOM/)
case $code in
  [23]??) ok "Jellyfin responde ($code) con la nueva config de Traefik";;
  *) bad "Jellyfin devolvió $code: revierto Traefik"; kubectl delete -f platform/traefik/helmchartconfig.yaml >/dev/null; rm -rf platform/traefik; exit 1;;
esac

echo "== 2) Prueba de IP de origen (necesito un dispositivo de tu LAN) =="
echo "   Desde tu PC o celular conectado a tu red de casa abrí:  http://$IP/   (verás 404, es normal)"
read -r -p "   Cuando lo hayas hecho, presioná Enter... " _
SEEN=$(kubectl -n kube-system logs deploy/traefik --since=15m | jq -R -r 'fromjson? | .ClientHost? // empty' | sort -u | tr '\n' ' ')
echo "   IPs de origen vistas por Traefik: $SEEN"
if echo "$SEEN" | tr ' ' '\n' | grep -E '^192\.168\.1\.' | grep -v "^$IP$" | grep -q .; then
  ok "Traefik ve IPs reales de la LAN"; GATE=1
else
  bad "Traefik NO ve IPs reales de la LAN. No publico las herramientas de administración (sería inseguro)."; GATE=0
fi

echo "== 3) Edito manifiestos en Git =="
cat > /tmp/phase3c.py <<'PY'
import yaml,glob,os,sys
H=os.path.expanduser('~/homelab'); mode=sys.argv[1]
def load(p): return yaml.safe_load(open(p))
def dump(p,o): open(p,'w').write(yaml.safe_dump(o,sort_keys=False))
if mode=='net':
    for f in glob.glob(H+'/apps/*/service-*.yaml'):
        o=load(f)
        if o.get('spec',{}).get('type')=='NodePort':
            o['spec']['type']='ClusterIP'
            for p in o['spec'].get('ports',[]): p.pop('nodePort',None)
            dump(f,o); print('  svc -> ClusterIP:',os.path.basename(f))
    MW='traefik.ingress.kubernetes.io/router.middlewares'; EP='traefik.ingress.kubernetes.io/router.entrypoints'
    def mw(ns): return {'apiVersion':'traefik.io/v1alpha1','kind':'Middleware','metadata':{'name':'lan-only','namespace':ns},
        'spec':{'ipAllowList':{'sourceRange':['192.168.1.0/24','100.64.0.0/10','127.0.0.1/32']}}}
    def ing(name,ns,host,svc,port): return {'apiVersion':'networking.k8s.io/v1','kind':'Ingress',
        'metadata':{'name':name,'namespace':ns,'annotations':{'cert-manager.io/cluster-issuer':'letsencrypt',MW:ns+'-lan-only@kubernetescrd',EP:'websecure'}},
        'spec':{'ingressClassName':'traefik','tls':[{'hosts':[host],'secretName':name+'-tls'}],
        'rules':[{'host':host,'http':{'paths':[{'path':'/','pathType':'Prefix','backend':{'service':{'name':svc,'port':{'number':port}}}}]}}]}}
    for d,ns in [('media','media'),('minio','minio'),('monitoring','monitoring'),('filebrowser','default')]:
        dump(f'{H}/apps/{d}/middleware-lan-only.yaml',mw(ns))
    dump(H+'/platform/argocd/middleware-lan-only.yaml',mw('argocd'))
    D='lyxar.dedyn.io'
    for d,ns,name,host,svc,port in [
        ('media','media','sonarr','sonarr.'+D,'sonarr',8989),('media','media','radarr','radarr.'+D,'radarr',7878),
        ('media','media','prowlarr','prowlarr.'+D,'prowlarr',9696),('media','media','qbittorrent','qbittorrent.'+D,'qbittorrent',8080),
        ('minio','minio','minio-console','minio.'+D,'minio',9001),('minio','minio','minio-s3','s3.'+D,'minio',9000),
        ('filebrowser','default','filebrowser','files.'+D,'filebrowser',8080)]:
        dump(f'{H}/apps/{d}/ingress-{name}.yaml',ing(name,ns,host,svc,port))
    for f,ns in [(H+'/apps/monitoring/ingress-grafana.yaml','monitoring'),(H+'/platform/argocd/ingress.yaml','argocd')]:
        o=load(f); a=o['metadata'].setdefault('annotations',{}); a[MW]=ns+'-lan-only@kubernetescrd'; a[EP]='websecure'; dump(f,o); print('  restringido a LAN:',ns)
if mode=='media':
    for n in ['sonarr','radarr','qbittorrent']:
        f=f'{H}/apps/media/deployment-{n}.yaml'; o=load(f); ch=False
        for v in o['spec']['template']['spec'].get('volumes',[]):
            if v.get('persistentVolumeClaim',{}).get('claimName')=='media-pvc':
                v.pop('persistentVolumeClaim'); v['hostPath']={'path':'/mnt/unified-media','type':'Directory'}; ch=True
        if ch: dump(f,o); print('  media por mergerfs:',n)
PY
[ "$GATE" = 1 ] && python3 /tmp/phase3c.py net
python3 /tmp/phase3c.py media
git add -A
git diff --cached --quiet && echo "  (sin cambios)" || git commit -qm "3c: traefik Local+accesslog, admin solo LAN/tailscale, ClusterIP, media via mergerfs"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }

echo "== 4) Esperando a ArgoCD (máx 8 min) =="
for i in $(seq 1 32); do
  for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  B=$(kubectl -n argocd get applications.argoproj.io --no-headers -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status | awk '$2!="Synced"||$3!="Healthy"')
  [ -z "$B" ] && break; sleep 15
done
[ -z "$B" ] && ok "todas las Applications Synced/Healthy" || { echo "$B"; bad "hay Applications sin sincronizar"; }

if [ "$GATE" = 1 ]; then
  echo "== 5) Certificados nuevos (máx 8 min) =="
  for i in $(seq 1 32); do
    N=$(kubectl get certificate -A --no-headers | awk '$3!="True"'); [ -z "$N" ] && break; sleep 15
  done
  [ -z "$N" ] && ok "todos los certificados Ready" || { echo "$N"; bad "faltan certificados (puede tardar; reintentá lab-check en unos minutos)"; }

  echo "== 6) Prueba de cada host (desde este servidor) =="
  for h in argocd grafana sonarr radarr prowlarr qbittorrent minio s3 files; do
    r=$(curl -s -o /dev/null -m 10 --resolve $h.$DOM:443:$IP -w '%{http_code} %{ssl_verify_result}' https://$h.$DOM/)
    echo "   $h.$DOM -> $r"
  done
  echo "   (200/302/401/403 de MinIO S3 son normales. 000 = cert o red; 403 en una UI = el filtro de IP te está bloqueando)"
  echo "== 7) Services que siguen NodePort =="
  kubectl get svc -A --no-headers | awk '$3=="NodePort"{print "   "$1"/"$2}'
fi
echo "== 8) /tv, /movies y /downloads en los pods =="
for p in sonarr:/tv radarr:/movies qbittorrent:/downloads; do
  echo "   ${p%%:*}: $(kubectl -n media exec deploy/${p%%:*} -- ls ${p##*:} 2>/dev/null | tr '\n' ' ')"
done
