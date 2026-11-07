#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab

echo "== 1) Git: PUID/PGID en las apps linuxserver y limpieza de anotaciones de Rancher =="
python3 - <<'PY'
import yaml,glob,re,os
rx=re.compile(r'^(field\.)?cattle\.io/')
def clean(a):
    if not a: return a
    for k in [k for k in a if rx.match(k)]: a.pop(k)
    return a or None
for f in glob.glob('apps/**/*.yaml',recursive=True):
    o=yaml.safe_load(open(f)); ch=False
    for m in (o.get('metadata',{}), o.get('spec',{}).get('template',{}).get('metadata',{})):
        a=m.get('annotations')
        if a and any(rx.match(k) for k in a):
            n=clean(a); ch=True
            if n is None: m.pop('annotations')
            else: m['annotations']=n
    if ch: print('  limpio:',f)
    if o.get('kind')=='Deployment' and os.path.basename(f) in ('deployment-sonarr.yaml','deployment-radarr.yaml','deployment-prowlarr.yaml','deployment-qbittorrent.yaml'):
        c=o['spec']['template']['spec']['containers'][0]
        env={e['name']:e for e in c.get('env',[])}
        for k,v in (('PUID','1000'),('PGID','1000'),('TZ','America/Argentina/Buenos_Aires')):
            env[k]={'name':k,'value':v}
        c['env']=list(env.values()); ch=True; print('  PUID/PGID:',f)
    if ch: open(f,'w').write(yaml.safe_dump(o,sort_keys=False))

p='bootstrap/appset-apps.yaml'; o=yaml.safe_load(open(p)); s=o['spec']['template']['spec']
s['ignoreDifferences']=[{'group':'*','kind':'*','jqPathExpressions':[
  '.metadata.annotations["field.cattle.io/publicEndpoints"]',
  '.metadata.annotations["field.cattle.io/ports"]']}]
opts=s['syncPolicy'].setdefault('syncOptions',[])
if 'RespectIgnoreDifferences=true' not in opts: opts.append('RespectIgnoreDifferences=true')
open(p,'w').write(yaml.safe_dump(o,sort_keys=False)); print('  appset actualizado')
PY
git add -A
git diff --cached --quiet && echo "  (sin cambios)" || git commit -qm "fix: PUID/PGID 1000 en apps linuxserver, ignorar anotaciones de Rancher" 
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
kubectl apply -f bootstrap/appset-apps.yaml >/dev/null && ok "ApplicationSet aplicado"

echo "== 2) Esperando a ArgoCD (máx 6 min) =="
for i in $(seq 1 24); do
  for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  kubectl -n media get deploy sonarr -o json | jq -e '[.spec.template.spec.containers[0].env[]?|select(.name=="PUID")]|length>0' >/dev/null && break
  sleep 15
done
for d in sonarr radarr prowlarr qbittorrent; do
  kubectl -n media rollout status deploy/$d --timeout=240s >/dev/null 2>&1 && ok "$d reiniciado con PUID=1000" || bad "$d no quedó Ready"
done
sleep 20
kubectl -n argocd get applications.argoproj.io

echo "== 3) Root folders =="
bash ~/homelab/scripts/rootfolders.sh
echo "== 4) Qué ven las apps de /config =="
for d in sonarr radarr; do echo "   $d: $(kubectl -n media exec deploy/$d -- stat -c 'uid=%u' /config/config.xml 2>&1)"; done
