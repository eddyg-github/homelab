#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }
q(){ kubectl get --raw "/api/v1/namespaces/monitoring/services/victoriametrics:8428/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null; }
D=apps/monitoring

echo "== 0) Pre-chequeos =="
for f in $D/vmagent-config.yaml $D/vmagent.yaml $D/configmap-otel-collector-config.yaml $D/deployment-otel-collector.yaml; do [ -s $f ] && ok "$f" || { bad "falta $f"; exit 1; }; done

echo "== 1) Edito vmagent y OTEL en Git =="
python3 - <<'PY' || { echo "  ❌ falló la edición"; exit 1; }
import os,yaml,hashlib
D=os.path.expanduser('~/homelab/apps/monitoring/')
class L(str): pass
yaml.add_representer(L,lambda d,s:d.represent_scalar('tag:yaml.org,2002:str',s,style='|'),Dumper=yaml.SafeDumper)
def lit(s): return L('\n'.join(l.rstrip() for l in s.strip('\n').split('\n'))+'\n')
hs=lambda s:hashlib.sha256(s.encode()).hexdigest()[:12]

# --- vmagent: jobs traefik y velero
f=D+'vmagent-config.yaml'; cm=yaml.safe_load(open(f)); s=cm['data']['scrape.yml']
if 'job_name: traefik' not in s:
    s=s.rstrip('\n')+'''
  - job_name: traefik
    kubernetes_sd_configs:
      - role: pod
        namespaces: {names: [kube-system]}
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name], regex: traefik, action: keep}
      - {source_labels: [__meta_kubernetes_pod_container_port_number], regex: '9100', action: keep}
      - {source_labels: [__meta_kubernetes_pod_name], target_label: pod}
  - job_name: velero
    kubernetes_sd_configs:
      - role: pod
        namespaces: {names: [velero]}
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_deploy], regex: velero, action: keep}
      - {source_labels: [__meta_kubernetes_pod_container_port_number], regex: '8085', action: keep}
      - {source_labels: [__meta_kubernetes_pod_name], target_label: pod}
'''
yaml.safe_load(s)  # valida
cm['data']['scrape.yml']=lit(s)
open(f,'w').write(yaml.safe_dump(cm,sort_keys=False,width=200))
f=D+'vmagent.yaml'; docs=list(yaml.safe_load_all(open(f)))
for d in docs:
    if d['kind']=='Deployment': d['spec']['template']['metadata']['annotations']['checksum/config']=hs(s)
yaml.safe_dump_all(docs,open(f,'w'),sort_keys=False,width=200)

# --- OTEL: fuera los jobs rotos
f=D+'configmap-otel-collector-config.yaml'; cm=yaml.safe_load(open(f)); cfg=yaml.safe_load(cm['data']['config.yaml'])
sc=cfg['receivers']['prometheus']['config']['scrape_configs']
keep=[j for j in sc if j['job_name'] not in ('traefik','kubernetes-pods')]
print('  OTEL jobs:',[j['job_name'] for j in sc],'->',[j['job_name'] for j in keep])
cfg['receivers']['prometheus']['config']['scrape_configs']=keep
txt=yaml.safe_dump(cfg,sort_keys=False,width=200)
cm['data']['config.yaml']=lit(txt)
open(f,'w').write(yaml.safe_dump(cm,sort_keys=False,width=200))
f=D+'deployment-otel-collector.yaml'; o=yaml.safe_load(open(f))
o['spec']['template'].setdefault('metadata',{}).setdefault('annotations',{})['checksum/config']=hs(txt)
open(f,'w').write(yaml.safe_dump(o,sort_keys=False,width=200))

# --- docs: backup manual sin heredar tracking
p=os.path.expanduser('~/homelab/docs/BACKUPS.md')
if os.path.exists(p):
    t=open(p).read()
    t=t.replace('velero backup create manual-$(date +%F) --from-schedule daily --wait','velero backup create manual-$(date +%F) --include-namespaces media,minio,monitoring,default,argocd,cert-manager,floci --wait   # no usar --from-schedule: hereda la anotación de ArgoCD y deja la app en Degraded')
    open(p,'w').write(t)
PY
ok "manifiestos editados"

echo "== 2) Dry-run y push =="
kubectl apply --dry-run=server -f $D/ >/tmp/dry6f.txt 2>&1 && ok "manifiestos válidos" || { head -15 /tmp/dry6f.txt; bad "dry-run falló, no se publica"; exit 1; }
git add -A; git diff --cached --quiet || git commit -qm "monitoring: jobs traefik y velero en vmagent; quitar jobs rotos del OTEL"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh
for i in $(seq 1 24); do kubectl -n monitoring get cm vmagent-config -o jsonpath='{.data.scrape\.yml}' | grep -q 'job_name: velero' && break; refresh; sleep 10; done
kubectl -n monitoring rollout status deploy/vmagent --timeout=240s >/dev/null 2>&1 && ok "vmagent Ready con los jobs nuevos" || { bad "vmagent no Ready"; kubectl -n monitoring logs deploy/vmagent --tail=8; }
kubectl -n monitoring rollout status deploy/otel-collector --timeout=240s >/dev/null 2>&1 && ok "otel-collector Ready" || { bad "otel-collector no Ready"; kubectl -n monitoring logs deploy/otel-collector --tail=8; }

echo "== 3) Backup: saco la anotación de ArgoCD =="
for b in $(kubectl -n velero get backups -o json | jq -r '.items[]|select(.metadata.annotations["argocd.argoproj.io/tracking-id"]!=null)|.metadata.name'); do
  kubectl -n velero annotate backup "$b" argocd.argoproj.io/tracking-id- >/dev/null && ok "limpiado $b"
done
refresh; sleep 20

echo "== 4) Esperando métricas (máx 4 min) =="
for i in $(seq 1 24); do
  T=$(q 'count({__name__=~"traefik_.*"})' | jq -r '.data.result[0].value[1] // 0'); V=$(q 'count({__name__=~"velero_backup.*"})' | jq -r '.data.result[0].value[1] // 0')
  [ "${T:-0}" -gt 0 ] && [ "${V:-0}" -gt 0 ] && break; sleep 10
done
echo "   series traefik_*: $T   series velero_backup*: $V"
[ "${T:-0}" -gt 0 ] && ok "métricas de Traefik llegando" || bad "sin métricas de Traefik"
[ "${V:-0}" -gt 0 ] && ok "métricas de Velero llegando" || bad "sin métricas de Velero"
echo "   targets por job:"; q 'sum by (job) (up)' | jq -r '.data.result[]|"     \(.metric.job)\t\(.value[1])"' | sort
echo "   traefik_service_requests_total: $(q 'count(traefik_service_requests_total)' | jq -r '.data.result[0].value[1] // 0') series"
echo "   último backup diario exitoso: $(q 'velero_backup_last_successful_timestamp{schedule="daily"}' | jq -r '.data.result[0].value[1] // "sin dato"')"

echo "== 5) platform-velero =="
refresh; sleep 20
H=$(kubectl -n argocd get application platform-velero -o jsonpath='{.status.health.status}')
[ "$H" = Healthy ] && ok "platform-velero Healthy" || { bad "platform-velero sigue $H. Detalle:"; kubectl -n argocd get application platform-velero -o json | jq -r '.status.resources[]|select(.health!=null)|"   \(.kind)/\(.name): \(.health.status) \(.health.message // "")"'; kubectl -n argocd get application platform-velero -o json | jq -c '{op:.status.operationState.phase, conds:.status.conditions}'; kubectl -n velero get backups,schedules; }
kubectl -n argocd get applications.argoproj.io
