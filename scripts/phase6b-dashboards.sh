#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }
F=apps/monitoring/configmap-grafana-dashboards.yaml
[ -s $F ] && ok "$F" || { bad "falta $F"; exit 1; }

echo "== 1) Genero dashboards =="
python3 - <<'PY' || { echo "  ❌ falló la generación"; exit 1; }
import os,json,yaml,hashlib,subprocess,urllib.parse
H=os.path.expanduser('~/homelab/'); F=H+'apps/monitoring/configmap-grafana-dashboards.yaml'
class L(str): pass
yaml.add_representer(L,lambda d,s:d.represent_scalar('tag:yaml.org,2002:str',s,style='|'),Dumper=yaml.SafeDumper)
def build(uid,title,items):
    panels=[];x=y=0;rowh=0;i=1
    for it in items:
        kind=it.get('kind','timeseries'); w=6 if kind=='stat' else 12; h=4 if kind=='stat' else 8
        if x+w>24: x=0;y+=rowh;rowh=0
        panels.append({"id":i,"type":kind,"title":it['t'],"datasource":"VictoriaMetrics",
          "gridPos":{"x":x,"y":y,"w":w,"h":h},"fieldConfig":{"defaults":{"unit":it.get('u','short')},"overrides":[]},
          "targets":[{"expr":e,"legendFormat":l,"refId":chr(65+n)} for n,(e,l) in enumerate(it['q'])]})
        x+=w;rowh=max(rowh,h);i+=1
    return {"uid":uid,"title":title,"schemaVersion":39,"version":1,"editable":True,"tags":["lab"],
            "time":{"from":"now-6h","to":"now"},"refresh":"1m","panels":panels}
S=lambda t,e,u='short':{'t':t,'kind':'stat','q':[(e,'')],'u':u}
T=lambda t,q,u='short':{'t':t,'q':q,'u':u}
D={}
D['servidor.json']=build('lab-servidor','Servidor (sparky)',[
 S('CPU %','100*(1-avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))','percent'),
 S('iowait %','100*avg(rate(node_cpu_seconds_total{mode="iowait"}[5m]))','percent'),
 S('Memoria usada','1-node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes','percentunit'),
 S('Uptime','time()-node_boot_time_seconds','s'),
 T('CPU por modo',[('100*avg by(mode)(rate(node_cpu_seconds_total{mode!="idle"}[5m]))','{{mode}}')],'percent'),
 T('Memoria',[('node_memory_MemTotal_bytes-node_memory_MemAvailable_bytes','usada'),('node_memory_Cached_bytes','cache'),('node_memory_MemTotal_bytes','total')],'bytes'),
 T('Load average',[('node_load1','1m'),('node_load5','5m'),('node_load15','15m')]),
 T('Presión PSI (tiempo detenido)',[('rate(node_pressure_io_stalled_seconds_total[5m])','io'),('rate(node_pressure_memory_stalled_seconds_total[5m])','memoria'),('rate(node_pressure_cpu_waiting_seconds_total[5m])','cpu espera')],'percentunit'),
 T('Disco ocupado (util)',[('rate(node_disk_io_time_seconds_total{device=~"sd[a-d]"}[5m])','{{device}}')],'percentunit'),
 T('Throughput de disco',[('rate(node_disk_read_bytes_total{device=~"sd[a-d]"}[5m])','lee {{device}}'),('rate(node_disk_written_bytes_total{device=~"sd[a-d]"}[5m])','escribe {{device}}')],'Bps'),
 T('Espacio libre',[('node_filesystem_avail_bytes{mountpoint=~"/|/mnt/media[234]"}','{{mountpoint}}')],'bytes'),
 T('Red',[('sum(rate(node_network_receive_bytes_total{device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*"}[5m]))','entrada'),('sum(rate(node_network_transmit_bytes_total{device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*"}[5m]))','salida')],'Bps'),
 T('Temperatura',[('node_hwmon_temp_celsius','{{chip}} {{sensor}}')],'celsius')])
D['discos.json']=build('lab-discos','Discos y SMART',[
 S('SMART OK (1=sí)','min(lab_smart_passed)'),
 S('Sectores pendientes (máx)','max(lab_smart_attribute_raw{name="current_pending_sector"})'),
 S('Sectores reasignados (máx)','max(lab_smart_attribute_raw{name="reallocated_sector_ct"})'),
 S('Temp. máx disco','max(lab_smart_attribute_raw{name="temperature_celsius"})','celsius'),
 T('Sectores pendientes',[('lab_smart_attribute_raw{name="current_pending_sector"}','{{device}}')]),
 T('Errores CRC (cable SATA)',[('lab_smart_attribute_raw{name="udma_crc_error_count"}','{{device}}')]),
 T('Temperatura',[('lab_smart_attribute_raw{name="temperature_celsius"}','{{device}}')],'celsius'),
 T('Horas encendido',[('lab_smart_attribute_raw{name="power_on_hours"}','{{device}}')],'h'),
 T('Latencia aprox. (io_time por IO)',[('rate(node_disk_io_time_weighted_seconds_total{device=~"sd[a-d]"}[5m])','{{device}}')],'s')])
D['k3s.json']=build('lab-k3s','k3s y pods',[
 S('Pods Running','sum(kube_pod_status_phase{phase="Running"})'),
 S('Pods con problema','sum(kube_pod_status_phase{phase=~"Pending|Failed|Unknown"})'),
 S('Reinicios (1h)','sum(increase(kube_pod_container_status_restarts_total[1h]))'),
 S('Nodos Ready','sum(kube_node_status_condition{condition="Ready",status="true"})'),
 T('CPU por namespace',[('sum by(namespace)(rate(container_cpu_usage_seconds_total{container!=""}[5m]))','{{namespace}}')]),
 T('Memoria por namespace',[('sum by(namespace)(container_memory_working_set_bytes{container!=""})','{{namespace}}')],'bytes'),
 T('Top 15 pods por memoria',[('topk(15,max by(namespace,pod)(container_memory_working_set_bytes{container!=""}))','{{namespace}}/{{pod}}')],'bytes'),
 T('Top 15 pods por CPU',[('topk(15,sum by(namespace,pod)(rate(container_cpu_usage_seconds_total{container!=""}[5m])))','{{namespace}}/{{pod}}')]),
 T('Reinicios por pod (1h)',[('increase(kube_pod_container_status_restarts_total[1h]) > 0','{{namespace}}/{{pod}}')]),
 T('Uso de volúmenes (PVC)',[('kubelet_volume_stats_used_bytes','{{namespace}}/{{persistentvolumeclaim}}')],'bytes'),
 T('API server: peticiones/s',[('sum by(code)(rate(apiserver_request_total[5m]))','{{code}}')])])
D['media.json']=build('lab-media','Media (Jellyfin y *arr)',[
 T('CPU por pod',[('sum by(pod)(rate(container_cpu_usage_seconds_total{namespace="media",container!=""}[5m]))','{{pod}}')]),
 T('Memoria por pod',[('max by(pod)(container_memory_working_set_bytes{namespace="media",container!=""})','{{pod}}')],'bytes'),
 T('Red recibida por pod',[('sum by(pod)(rate(container_network_receive_bytes_total{namespace="media"}[5m]))','{{pod}}')],'Bps'),
 T('Red enviada por pod (streaming)',[('sum by(pod)(rate(container_network_transmit_bytes_total{namespace="media"}[5m]))','{{pod}}')],'Bps'),
 T('Peticiones web a Jellyfin',[('sum by(code)(rate(traefik_service_requests_total{service=~".*jellyfin.*"}[5m]))','{{code}}')]),
 T('Presión de I/O (afecta a Jellyfin)',[('rate(node_pressure_io_stalled_seconds_total[5m])','io')],'percentunit'),
 T('Espacio libre media',[('node_filesystem_avail_bytes{mountpoint=~"/mnt/media[234]"}','{{mountpoint}}')],'bytes')])
D['plataforma.json']=build('lab-plataforma','Plataforma (ArgoCD, certs, Traefik, backups)',[
 S('Apps ArgoCD fuera de Git','count(argocd_app_info{sync_status!="Synced"}) or vector(0)'),
 S('Apps no Healthy','count(argocd_app_info{health_status!="Healthy"}) or vector(0)'),
 S('Cert. que vence antes (días)','min(certmanager_certificate_expiration_timestamp_seconds-time())/86400','d'),
 S('Último backup (horas)','(time()-max(velero_backup_last_successful_timestamp{schedule="daily"}))/3600','h'),
 T('Estado de apps ArgoCD',[('argocd_app_info','{{name}} {{sync_status}}/{{health_status}}')]),
 T('Vencimiento de certificados (días)',[('(certmanager_certificate_expiration_timestamp_seconds-time())/86400','{{namespace}}/{{name}}')],'d'),
 T('Peticiones Traefik por código',[('sum by(code)(rate(traefik_service_requests_total[5m]))','{{code}}')]),
 T('Peticiones por servicio',[('topk(10,sum by(service)(rate(traefik_service_requests_total[5m])))','{{service}}')]),
 T('MinIO: uso por bucket',[('minio_bucket_usage_total_bytes','{{bucket}}')],'bytes'),
 T('MinIO: espacio libre',[('minio_cluster_capacity_usable_free_bytes','libre')],'bytes'),
 T('Backups Velero: edad del último exitoso',[('time()-velero_backup_last_successful_timestamp','{{schedule}}')],'s'),
 T('Backups Velero: fallos',[('velero_backup_failure_total','{{schedule}}')])])
D['host.json']=build('lab-host','Host, Docker y Guacamole',[
 S('Paquetes pendientes (apt)','sum(lab_pending_updates{source="apt"})'),
 S('Reinicio requerido','max(lab_reboot_required)'),
 S('Servicios systemd fallidos','max(lab_systemd_failed_units)'),
 S('Última actualización (h)','(time()-lab_updn_last_success_timestamp_seconds)/3600','h'),
 T('Paquetes pendientes por fuente',[('lab_pending_updates','{{source}}')]),
 T('Docker: CPU por contenedor',[('lab_docker_container_cpu_percent','{{name}}')],'percent'),
 T('Docker: memoria por contenedor',[('lab_docker_container_memory_bytes','{{name}}')],'bytes'),
 T('LocalStack: servicios activos',[('sum(lab_localstack_service_running)','running')]),
 T('Guacamole: CPU y memoria',[('sum by(pod)(rate(container_cpu_usage_seconds_total{namespace="guacamole",container!=""}[5m]))','cpu {{pod}}')]),
 T('Guacamole: memoria',[('max by(pod)(container_memory_working_set_bytes{namespace="guacamole",container!=""})','{{pod}}')],'bytes'),
 T('Guacamole: peticiones web',[('sum by(code)(rate(traefik_service_requests_total{service=~".*guacamole.*"}[5m]))','{{code}}')])])

# --- probar cada consulta contra VictoriaMetrics
def q(e):
    u='/api/v1/namespaces/monitoring/services/victoriametrics:8428/proxy/api/v1/query?query='+urllib.parse.quote(e)
    r=subprocess.run(['kubectl','get','--raw',u],capture_output=True,text=True)
    try: return len(json.loads(r.stdout)['data']['result'])
    except Exception: return -1
empty=[]
for k,d in D.items():
    for p in d['panels']:
        for t in p['targets']:
            n=q(t['expr'])
            if n<=0: empty.append((d['title'],p['title'],'error' if n<0 else 'sin datos'))
print('  paneles totales:',sum(len(d['panels']) for d in D.values()))
print('  paneles sin datos o con error:',len(empty))
for e in empty: print('     -',*e)

cm=yaml.safe_load(open(F)); cm['data']=cm.get('data') or {}
for k,d in D.items(): cm['data'][k]=L(json.dumps(d,indent=1,ensure_ascii=False)+'\n')
size=sum(len(v) for v in cm['data'].values()); print('  tamaño del ConfigMap:',size,'bytes (límite ~1 MiB)')
assert size<900000
open(F,'w').write(yaml.safe_dump(cm,sort_keys=False,width=200,allow_unicode=True))
g=H+'apps/monitoring/deployment-grafana.yaml'; o=yaml.safe_load(open(g))
o['spec']['template'].setdefault('metadata',{}).setdefault('annotations',{})['checksum/dashboards']=hashlib.sha256(str(cm['data']).encode()).hexdigest()[:12]
open(g,'w').write(yaml.safe_dump(o,sort_keys=False,width=200))
PY
ok "dashboards generados"

echo "== 2) Dry-run y push =="
kubectl apply --dry-run=server -f apps/monitoring/ >/tmp/dry6b.txt 2>&1 && ok "manifiestos válidos" || { head -10 /tmp/dry6b.txt; bad "dry-run falló, no se publica"; exit 1; }
git add -A; git diff --cached --quiet || git commit -qm "grafana: 6 dashboards como codigo (servidor, discos, k3s, media, plataforma, host)"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh
for i in $(seq 1 30); do kubectl -n monitoring get cm grafana-dashboards -o jsonpath='{.data}' | grep -q lab-discos && break; refresh; sleep 10; done
kubectl -n monitoring rollout status deploy/grafana --timeout=240s >/dev/null 2>&1 && ok "grafana Ready" || bad "grafana no Ready"
sleep 20
echo "== 3) Grafana los cargó =="
kubectl -n monitoring logs deploy/grafana --tail=200 | grep -i -E 'provision|dashboard' | grep -i -E 'error|fail' | tail -5 | cut -c1-200
kubectl -n monitoring exec deploy/grafana -- ls /var/lib/grafana/dashboards
echo "   Abrí https://grafana.lyxar.dedyn.io -> Dashboards -> carpeta 'Cluster' (por LAN o VPN)"
kubectl -n argocd get applications.argoproj.io app-monitoring --no-headers
