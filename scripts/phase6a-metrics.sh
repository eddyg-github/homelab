#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
BK=~/homelab-backup; CN=sealed-secrets-controller; CNS=kube-system
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }
q(){ kubectl get --raw "/api/v1/namespaces/monitoring/services/victoriametrics:8428/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null; }
tg(){ curl -s -m 15 -K - "${@:2}" <<<"url = \"https://api.telegram.org/bot${TOKEN}/$1\""; }

echo "== 0) Pre-chequeos =="
command -v kubeseal >/dev/null && ok "kubeseal" || { bad "falta kubeseal"; exit 1; }
kubectl -n $CNS get deploy $CN >/dev/null 2>&1 && ok "Sealed Secrets presente" || { bad "falta Sealed Secrets"; exit 1; }
kubectl -n monitoring get sts victoriametrics >/dev/null 2>&1 && ok "VictoriaMetrics presente" || { bad "falta VictoriaMetrics"; exit 1; }
[ -f apps/monitoring/deployment-vmalert.yaml ] && [ -f apps/monitoring/configmap-vmalert-rules.yaml ] && ok "manifiestos de vmalert en Git" || { bad "faltan manifiestos de vmalert en Git"; exit 1; }
curl -s -m 10 -o /dev/null https://api.telegram.org && ok "sparky llega a api.telegram.org" || { bad "sparky no llega a api.telegram.org"; exit 1; }

echo "== 1) Telegram =="
SEALED=apps/monitoring/sealedsecret-alertmanager-telegram.yaml; CHATF=$BK/telegram-chat-id; REUSE=0; TOKEN=""
if [ -s "$SEALED" ] && [ -s "$CHATF" ] && [ "${RESET:-0}" != 1 ]; then CHAT=$(cat "$CHATF"); REUSE=1; ok "reutilizo el bot ya configurado (chat $CHAT)"; fi
if [ $REUSE = 0 ]; then
  echo "   Pegá el token del bot (no se ve al escribirlo) y presioná Enter:"
  read -rs TOKEN; echo
  [ -n "$TOKEN" ] || { bad "token vacío"; exit 1; }
  BOT=$(tg getMe | jq -r 'select(.ok==true)|.result.username')
  [ -n "$BOT" ] && ok "token válido: @$BOT" || { bad "Telegram rechazó el token (¿lo copiaste completo?)"; exit 1; }
  CHAT=$(tg getUpdates | jq -r '[.result[]?|(.message.chat.id // empty)]|last // empty')
  [ -n "$CHAT" ] || { bad "el bot no recibió ningún mensaje. En Telegram buscá @$BOT, tocá Start, escribile 'hola' y ejecutá el script de nuevo."; exit 1; }
  ( umask 077; echo "$CHAT" > "$CHATF" )
  tg sendMessage --data-urlencode "chat_id=$CHAT" --data-urlencode "text=🔧 Lab sparky: conexión con Telegram OK" | jq -e .ok >/dev/null \
    && ok "mensaje de prueba enviado a tu Telegram" || { bad "no pude enviar el mensaje"; exit 1; }
  [ -s sealed-secrets-pub.crt ] || kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt
  TOK="$TOKEN" jq -n '{apiVersion:"v1",kind:"Secret",metadata:{name:"alertmanager-telegram",namespace:"monitoring"},type:"Opaque",data:{token:(env.TOK|@base64)}}' \
    | kubeseal --cert sealed-secrets-pub.crt --format yaml > "$SEALED" && [ -s "$SEALED" ] \
    && ok "token cifrado (SealedSecret)" || { bad "no pude cifrar el token"; rm -f "$SEALED"; exit 1; }
fi

echo "== 2) Genero manifiestos en apps/monitoring/ =="
export CHAT
python3 - <<'PY'
import os,yaml,hashlib
D=os.path.expanduser('~/homelab/apps/monitoring/'); NS='monitoring'; CHAT=int(os.environ['CHAT'])
class L(str): pass
yaml.add_representer(L,lambda d,s:d.represent_scalar('tag:yaml.org,2002:str',s,style='|'),Dumper=yaml.SafeDumper)
def lit(s): return L('\n'.join(l.rstrip() for l in s.strip('\n').split('\n'))+'\n')
def put(name,*docs):
    with open(D+name,'w') as f: yaml.safe_dump_all(docs,f,sort_keys=False,width=200)
def md(name,**kw): m={'name':name,'namespace':NS}; m.update(kw); return m
def hs(s): return hashlib.sha256(s.encode()).hexdigest()[:12]
def svc(name,port,sel=None):
    return {'apiVersion':'v1','kind':'Service','metadata':md(name),'spec':{'selector':{'app':sel or name},'ports':[{'name':'http','port':port,'targetPort':port}]}}
def ingress(name,host,s,port):
    return {'apiVersion':'networking.k8s.io/v1','kind':'Ingress','metadata':md(name,annotations={
      'cert-manager.io/cluster-issuer':'letsencrypt','traefik.ingress.kubernetes.io/router.middlewares':'monitoring-lan-only@kubernetescrd','traefik.ingress.kubernetes.io/router.entrypoints':'websecure'}),
      'spec':{'ingressClassName':'traefik','tls':[{'hosts':[host],'secretName':name+'-tls'}],
      'rules':[{'host':host,'http':{'paths':[{'path':'/','pathType':'Prefix','backend':{'service':{'name':s,'port':{'number':port}}}}]}}]}}

SCRAPE='''
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: node-exporter
    static_configs:
      - targets: ['node-exporter.monitoring.svc.cluster.local:9101']
        labels: {node: sparky}
  - job_name: cadvisor
    scheme: https
    scrape_timeout: 25s
    tls_config: {insecure_skip_verify: true}
    authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
    kubernetes_sd_configs: [{role: node}]
    relabel_configs:
      - {target_label: __address__, replacement: 'kubernetes.default.svc:443'}
      - {source_labels: [__meta_kubernetes_node_name], target_label: __metrics_path__, replacement: '/api/v1/nodes/$1/proxy/metrics/cadvisor'}
      - {source_labels: [__meta_kubernetes_node_name], target_label: node}
    metric_relabel_configs:
      - {source_labels: [__name__], regex: 'container_(tasks_state|network_tcp_usage_total|network_udp_usage_total)', action: drop}
  - job_name: kubelet
    scheme: https
    scrape_timeout: 25s
    tls_config: {insecure_skip_verify: true}
    authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
    kubernetes_sd_configs: [{role: node}]
    relabel_configs:
      - {target_label: __address__, replacement: 'kubernetes.default.svc:443'}
      - {source_labels: [__meta_kubernetes_node_name], target_label: __metrics_path__, replacement: '/api/v1/nodes/$1/proxy/metrics'}
      - {source_labels: [__meta_kubernetes_node_name], target_label: node}
  - job_name: apiserver
    scheme: https
    scrape_timeout: 25s
    tls_config: {insecure_skip_verify: true}
    authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
    static_configs:
      - targets: ['kubernetes.default.svc:443']
    metric_relabel_configs:
      - {source_labels: [__name__], regex: 'apiserver_request_(slo|sli)_duration_seconds_bucket|apiserver_response_sizes_bucket|apiserver_watch_events_sizes_bucket', action: drop}
  - job_name: victoriametrics
    static_configs: [{targets: ['victoriametrics.monitoring.svc.cluster.local:8428']}]
  - job_name: vmalert
    static_configs: [{targets: ['vmalert.monitoring.svc.cluster.local:8880']}]
  - job_name: vmagent
    static_configs: [{targets: ['vmagent.monitoring.svc.cluster.local:8429']}]
  - job_name: alertmanager
    static_configs: [{targets: ['alertmanager.monitoring.svc.cluster.local:9093']}]
  - job_name: grafana
    static_configs: [{targets: ['grafana.monitoring.svc.cluster.local:3000']}]
  - job_name: minio
    metrics_path: /minio/v2/metrics/cluster
    static_configs: [{targets: ['minio.minio.svc.cluster.local:9000']}]
'''
RULES='''
groups:
  - name: servidor
    interval: 60s
    rules:
      - alert: NodeExporterDown
        expr: up{job="node-exporter"} == 0
        for: 2m
        labels: {severity: critical}
        annotations:
          summary: "node-exporter no responde: no hay métricas del servidor"
      - alert: HighMemoryUsage
        expr: 1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes > 0.90
        for: 5m
        labels: {severity: warning}
        annotations:
          summary: "Memoria del servidor al {{ $value | humanizePercentage }}"
      - alert: HighCPU
        expr: 1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.90
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "CPU del servidor al {{ $value | humanizePercentage }} durante 10 min"
      - alert: HighIOWait
        expr: avg(rate(node_cpu_seconds_total{mode="iowait"}[5m])) > 0.20
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Los discos están frenando al CPU (iowait {{ $value | humanizePercentage }}): Jellyfin puede cortarse"
      - alert: DiskBusy
        expr: rate(node_disk_io_time_seconds_total{device=~"sd[a-d]"}[5m]) > 0.90
        for: 15m
        labels: {severity: warning}
        annotations:
          summary: "Disco {{ $labels.device }} saturado ({{ $value | humanizePercentage }} ocupado)"
      - alert: SystemDiskLow
        expr: node_filesystem_avail_bytes{mountpoint="/"} < 25 * 1024 * 1024 * 1024
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Disco del sistema con solo {{ $value | humanize1024 }}B libres"
      - alert: SystemDiskCritical
        expr: node_filesystem_avail_bytes{mountpoint="/"} < 10 * 1024 * 1024 * 1024
        for: 5m
        labels: {severity: critical}
        annotations:
          summary: "Disco del sistema casi lleno: {{ $value | humanize1024 }}B libres. k3s puede desalojar pods"
      - alert: MediaDiskLow
        expr: node_filesystem_avail_bytes{mountpoint=~"/mnt/media[234]"} / node_filesystem_size_bytes{mountpoint=~"/mnt/media[234]"} < 0.05
        for: 15m
        labels: {severity: warning}
        annotations:
          summary: "Disco {{ $labels.mountpoint }} con menos del 5% libre"
      - alert: FilesystemReadOnly
        expr: node_filesystem_readonly{mountpoint=~"/|/mnt/media[234]"} == 1
        for: 1m
        labels: {severity: critical}
        annotations:
          summary: "{{ $labels.mountpoint }} pasó a solo lectura (posible falla de disco)"
      - alert: HighTemperature
        expr: node_hwmon_temp_celsius > 80
        for: 5m
        labels: {severity: warning}
        annotations:
          summary: "Temperatura alta: {{ $value }} C en {{ $labels.chip }}"
      - alert: ServerRebooted
        expr: node_time_seconds - node_boot_time_seconds < 600
        labels: {severity: info}
        annotations:
          summary: "El servidor se reinició hace menos de 10 minutos"
  - name: kubernetes
    interval: 60s
    rules:
      - alert: ScrapeTargetDown
        expr: up == 0
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "No hay métricas de {{ $labels.job }} ({{ $labels.instance }})"
      - alert: NodeNotReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 2m
        labels: {severity: critical}
        annotations:
          summary: "El nodo {{ $labels.node }} no está Ready"
      - alert: PodCrashLooping
        expr: increase(kube_pod_container_status_restarts_total[15m]) > 3
        for: 5m
        labels: {severity: warning}
        annotations:
          summary: "{{ $labels.namespace }}/{{ $labels.pod }} se reinicia en bucle"
      - alert: PodNotRunning
        expr: sum by (namespace, pod) (kube_pod_status_phase{phase=~"Pending|Unknown|Failed"}) > 0
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "{{ $labels.namespace }}/{{ $labels.pod }} no está corriendo"
      - alert: DeploymentUnavailable
        expr: kube_deployment_status_replicas_available < kube_deployment_spec_replicas
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "{{ $labels.namespace }}/{{ $labels.deployment }} sin todas sus réplicas disponibles"
      - alert: ContainerOOMKilled
        expr: (increase(kube_pod_container_status_restarts_total[10m]) > 0) and on(namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1)
        labels: {severity: warning}
        annotations:
          summary: "{{ $labels.namespace }}/{{ $labels.pod }} fue matado por falta de memoria (OOM)"
      - alert: ContainerMemoryNearLimit
        expr: max by (namespace, pod, container) (container_memory_working_set_bytes{container!="",container!="POD"}) / on(namespace, pod, container) max by (namespace, pod, container) (kube_pod_container_resource_limits{resource="memory"}) > 0.90
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "{{ $labels.namespace }}/{{ $labels.pod }} usa {{ $value | humanizePercentage }} de su límite de memoria"
      - alert: PVCPending
        expr: kube_persistentvolumeclaim_status_phase{phase="Pending"} == 1
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} sin volumen"
  - name: plataforma
    interval: 60s
    rules:
      - alert: CertExpiringSoon
        expr: certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 24 * 3600
        for: 1h
        labels: {severity: warning}
        annotations:
          summary: "El certificado {{ $labels.namespace }}/{{ $labels.name }} vence en menos de 14 días"
      - alert: CertNotReady
        expr: certmanager_certificate_ready_status{condition="True"} == 0
        for: 30m
        labels: {severity: warning}
        annotations:
          summary: "El certificado {{ $labels.namespace }}/{{ $labels.name }} no está Ready"
      - alert: ArgoAppOutOfSync
        expr: argocd_app_info{sync_status!="Synced"} == 1
        for: 20m
        labels: {severity: warning}
        annotations:
          summary: "La app {{ $labels.name }} de ArgoCD no coincide con Git"
      - alert: ArgoAppUnhealthy
        expr: argocd_app_info{health_status!~"Healthy|Progressing"} == 1
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "La app {{ $labels.name }} de ArgoCD está {{ $labels.health_status }}"
      - alert: TraefikHigh5xx
        expr: sum(rate(traefik_service_requests_total{code=~"5.."}[5m])) / sum(rate(traefik_service_requests_total[5m])) > 0.05
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Más del 5% de las peticiones web dan error 5xx"
      - alert: MinIODown
        expr: up{job="minio"} == 0
        for: 5m
        labels: {severity: critical}
        annotations:
          summary: "MinIO no responde (los backups de Velero dependen de él)"
      - alert: VeleroBackupStale
        expr: time() - velero_backup_last_successful_timestamp{schedule="daily"} > 129600
        for: 10m
        labels: {severity: critical}
        annotations:
          summary: "El último backup diario exitoso tiene más de 36 horas"
      - alert: VeleroBackupFailed
        expr: increase(velero_backup_failure_total{schedule="daily"}[1d]) > 0
        labels: {severity: warning}
        annotations:
          summary: "Falló un backup diario de Velero en las últimas 24 horas"
'''
AMCFG='''
global:
  resolve_timeout: 5m
route:
  receiver: telegram
  group_by: [alertname, namespace]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  routes:
    - matchers: ['severity="critical"']
      receiver: telegram
      repeat_interval: 4h
inhibit_rules:
  - source_matchers: ['severity="critical"']
    target_matchers: ['severity="warning"']
    equal: [alertname, namespace]
receivers:
  - name: telegram
    telegram_configs:
      - bot_token_file: /etc/alertmanager-secrets/token
        chat_id: %d
        send_resolved: true
        parse_mode: ''
        message: |-
          {{ range .Alerts }}{{ if eq .Status "firing" }}{{ if eq .Labels.severity "critical" }}🔴 CRÍTICA{{ else if eq .Labels.severity "info" }}🔵 INFO{{ else }}🟠 AVISO{{ end }}{{ else }}✅ RESUELTA{{ end }}: {{ .Labels.alertname }}
          {{ .Annotations.summary }}
          {{ end }}
''' % CHAT

def cm(name,key,text): return {'apiVersion':'v1','kind':'ConfigMap','metadata':md(name),'data':{key:lit(text)}}
res=lambda r,m,c=None:{'requests':{'cpu':r,'memory':m},'limits':{'memory':c or m}}

# ---- RBAC + vmagent
put('vmagent-rbac.yaml',
  {'apiVersion':'v1','kind':'ServiceAccount','metadata':md('vmagent')},
  {'apiVersion':'rbac.authorization.k8s.io/v1','kind':'ClusterRole','metadata':{'name':'vmagent-scrape'},'rules':[
    {'apiGroups':[''],'resources':['nodes','nodes/metrics','nodes/proxy','services','endpoints','pods'],'verbs':['get','list','watch']},
    {'nonResourceURLs':['/metrics','/metrics/cadvisor'],'verbs':['get']}]},
  {'apiVersion':'rbac.authorization.k8s.io/v1','kind':'ClusterRoleBinding','metadata':{'name':'vmagent-scrape'},
   'roleRef':{'apiGroup':'rbac.authorization.k8s.io','kind':'ClusterRole','name':'vmagent-scrape'},
   'subjects':[{'kind':'ServiceAccount','name':'vmagent','namespace':NS}]})
put('vmagent-config.yaml',cm('vmagent-config','scrape.yml',SCRAPE))
put('vmagent.yaml',
  {'apiVersion':'apps/v1','kind':'Deployment','metadata':md('vmagent'),'spec':{'replicas':1,'selector':{'matchLabels':{'app':'vmagent'}},
   'template':{'metadata':{'labels':{'app':'vmagent'},'annotations':{'checksum/config':hs(SCRAPE)}},'spec':{'serviceAccountName':'vmagent',
    'containers':[{'name':'vmagent','image':'victoriametrics/vmagent:v1.93.4',
      'args':['-promscrape.config=/config/scrape.yml','-remoteWrite.url=http://victoriametrics.monitoring.svc.cluster.local:8428/api/v1/write','-remoteWrite.tmpDataPath=/tmp/vmagent-queue','-httpListenAddr=:8429'],
      'ports':[{'containerPort':8429}],'resources':res('50m','128Mi','512Mi'),
      'readinessProbe':{'httpGet':{'path':'/health','port':8429}},
      'volumeMounts':[{'name':'config','mountPath':'/config'},{'name':'tmp','mountPath':'/tmp'}]}],
    'volumes':[{'name':'config','configMap':{'name':'vmagent-config'}},{'name':'tmp','emptyDir':{}}]}}}},
  svc('vmagent',8429))

# ---- node-exporter
EXC='^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/kubelet/.+|var/lib/rancher/k3s/(agent|storage)/.+|mnt/unified-source/.+)($|/)'
put('node-exporter.yaml',
  {'apiVersion':'apps/v1','kind':'DaemonSet','metadata':md('node-exporter'),'spec':{'selector':{'matchLabels':{'app':'node-exporter'}},
   'template':{'metadata':{'labels':{'app':'node-exporter'}},'spec':{'hostNetwork':True,'hostPID':True,'dnsPolicy':'ClusterFirstWithHostNet',
    'tolerations':[{'operator':'Exists'}],'securityContext':{'runAsUser':65534,'runAsNonRoot':True},
    'containers':[{'name':'node-exporter','image':'prom/node-exporter:v1.8.2',
      'args':['--path.rootfs=/host/root','--web.listen-address=:9101','--collector.filesystem.mount-points-exclude='+EXC,'--collector.netdev.device-exclude=^(veth.*|cni0|flannel.*|lo)$'],
      'ports':[{'containerPort':9101,'name':'metrics'}],'resources':res('30m','48Mi','128Mi'),
      'volumeMounts':[{'name':'root','mountPath':'/host/root','readOnly':True,'mountPropagation':'HostToContainer'}]}],
    'volumes':[{'name':'root','hostPath':{'path':'/'}}]}}}},
  svc('node-exporter',9101))

# ---- alertmanager
put('alertmanager-config.yaml',cm('alertmanager-config','alertmanager.yml',AMCFG))
put('alertmanager.yaml',
  {'apiVersion':'v1','kind':'PersistentVolumeClaim','metadata':md('alertmanager-data'),'spec':{'accessModes':['ReadWriteOnce'],'storageClassName':'local-path','resources':{'requests':{'storage':'1Gi'}}}},
  {'apiVersion':'apps/v1','kind':'Deployment','metadata':md('alertmanager'),'spec':{'replicas':1,'strategy':{'type':'Recreate'},'selector':{'matchLabels':{'app':'alertmanager'}},
   'template':{'metadata':{'labels':{'app':'alertmanager'},'annotations':{'checksum/config':hs(AMCFG)}},'spec':{'securityContext':{'runAsUser':65534,'runAsNonRoot':True,'fsGroup':65534},
    'containers':[{'name':'alertmanager','image':'prom/alertmanager:v0.27.0',
      'args':['--config.file=/etc/alertmanager/alertmanager.yml','--storage.path=/alertmanager','--web.listen-address=:9093','--data.retention=240h','--web.external-url=https://alertmanager.lyxar.dedyn.io'],
      'ports':[{'containerPort':9093}],'resources':res('20m','48Mi','192Mi'),
      'readinessProbe':{'httpGet':{'path':'/-/ready','port':9093}},
      'volumeMounts':[{'name':'config','mountPath':'/etc/alertmanager','readOnly':True},{'name':'tgsecret','mountPath':'/etc/alertmanager-secrets','readOnly':True},{'name':'data','mountPath':'/alertmanager'}]}],
    'volumes':[{'name':'config','configMap':{'name':'alertmanager-config'}},{'name':'tgsecret','secret':{'secretName':'alertmanager-telegram','defaultMode':0o440}},{'name':'data','persistentVolumeClaim':{'claimName':'alertmanager-data'}}]}}}},
  svc('alertmanager',9093))

# ---- vmalert: reglas nuevas, Service y notificador real
c=yaml.safe_load(open(D+'configmap-vmalert-rules.yaml')); c['data']={'rules.yaml':lit(RULES)}
open(D+'configmap-vmalert-rules.yaml','w').write(yaml.safe_dump(c,sort_keys=False,width=200))
f=D+'deployment-vmalert.yaml'; o=yaml.safe_load(open(f)); ct=o['spec']['template']['spec']['containers'][0]
ct['args']=[a for a in ct['args'] if not a.startswith('-notifier.')]+['-notifier.url=http://alertmanager.monitoring.svc.cluster.local:9093']
o['spec']['template'].setdefault('metadata',{}).setdefault('annotations',{})['checksum/rules']=hs(RULES)
open(f,'w').write(yaml.safe_dump(o,sort_keys=False,width=200))
put('vmalert-service.yaml',svc('vmalert',8880))

# ---- URLs (solo LAN)
put('ingress-alertmanager.yaml',ingress('alertmanager','alertmanager.lyxar.dedyn.io','alertmanager',9093))
put('ingress-victoriametrics.yaml',ingress('victoriametrics','vm.lyxar.dedyn.io','victoriametrics',8428))
for fn in ('vmagent-rbac.yaml','vmagent-config.yaml','vmagent.yaml','node-exporter.yaml','alertmanager-config.yaml','alertmanager.yaml','vmalert-service.yaml','configmap-vmalert-rules.yaml'):
    yaml.safe_load_all(open(D+fn)); 
print('  archivos generados')
PY
[ $? = 0 ] && ok "manifiestos generados" || { bad "falló la generación"; exit 1; }

echo "== 3) Chequeo de fugas y dry-run =="
if [ -n "$TOKEN" ] && grep -rqF --exclude-dir=.git -- "$TOKEN" . ; then bad "el token aparece en claro en el repo. NO se publica"; exit 1; fi
ok "el token no está en claro en el repo"
kubectl apply --dry-run=server -f apps/monitoring/ >/tmp/dry6.txt 2>&1 && ok "los manifiestos son válidos para el cluster" || { head -15 /tmp/dry6.txt; bad "dry-run falló, no se publica"; exit 1; }

echo "== 4) Push y sincronización =="
git add -A; git diff --cached --quiet || git commit -qm "monitoring: node-exporter, cadvisor/kubelet (vmagent), alertmanager+telegram, reglas de alerta"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh
for i in $(seq 1 30); do kubectl -n monitoring get ds node-exporter >/dev/null 2>&1 && kubectl -n monitoring get deploy alertmanager vmagent >/dev/null 2>&1 && break; refresh; sleep 10; done
kubectl -n monitoring rollout status ds/node-exporter --timeout=240s >/dev/null 2>&1 && ok "node-exporter Ready" || { bad "node-exporter no Ready"; kubectl -n monitoring get pods | grep node-exporter; }
kubectl -n monitoring rollout status deploy/vmagent --timeout=240s >/dev/null 2>&1 && ok "vmagent Ready" || { bad "vmagent no Ready"; kubectl -n monitoring logs deploy/vmagent --tail=8 2>&1; }
kubectl -n monitoring rollout status deploy/alertmanager --timeout=240s >/dev/null 2>&1 && ok "alertmanager Ready" || { bad "alertmanager no Ready"; kubectl -n monitoring logs deploy/alertmanager --tail=8 2>&1; kubectl -n monitoring get sealedsecret,secret | grep alertmanager; }
for i in $(seq 1 24); do kubectl -n monitoring get deploy vmalert -o json | jq -e '.spec.template.spec.containers[0].args|any(startswith("-notifier.url"))' >/dev/null && break; refresh; sleep 10; done
kubectl -n monitoring rollout status deploy/vmalert --timeout=240s >/dev/null 2>&1 && ok "vmalert Ready con Alertmanager como destino" || bad "vmalert no Ready"

echo "== 5) Métricas llegando (espero hasta 5 min) =="
for i in $(seq 1 30); do
  N=$(q 'count(up{job=~"node-exporter|cadvisor|kubelet|apiserver"}==1)' | jq -r '.data.result[0].value[1] // 0')
  [ "${N:-0}" -ge 4 ] && break; sleep 10
done
echo "   targets por job (1 = responde, 0 = caído):"
q 'sum by (job) (up)' | jq -r '.data.result[]|"     \(.metric.job)\t\(.value[1])"' | sort
echo "   familias de métricas disponibles:"
for m in node_cpu_seconds_total node_disk_io_time_seconds_total node_hwmon_temp_celsius container_cpu_usage_seconds_total container_memory_working_set_bytes kube_pod_status_phase kubelet_volume_stats_used_bytes argocd_app_info certmanager_certificate_ready_status traefik_service_requests_total velero_backup_last_successful_timestamp minio_cluster_capacity_usable_free_bytes minio_bucket_usage_total_bytes; do
  n=$(q "count({__name__=\"$m\"})" | jq -r '.data.result[0].value[1] // 0'); printf '     %-48s %s series\n' "$m" "$n"
done
[ "${N:-0}" -ge 4 ] && ok "node-exporter, cadvisor, kubelet y apiserver responden" || bad "faltan targets (ver lista arriba)"

echo "== 6) Reglas de alerta =="
R=$(kubectl get --raw /api/v1/namespaces/monitoring/services/vmalert:8880/proxy/api/v1/rules 2>/dev/null)
echo "   grupos: $(jq -r '.data.groups|length' <<<"$R" 2>/dev/null)  reglas: $(jq -r '[.data.groups[].rules[]]|length' <<<"$R" 2>/dev/null)"
E=$(jq -r '[.data.groups[].rules[]|select((.lastError//"")!="")|.name]|join(", ")' <<<"$R" 2>/dev/null)
[ -z "$E" ] && ok "todas las reglas se evalúan sin error" || bad "reglas con error: $E"
echo "   alertas activas ahora: $(jq -r '[.data.groups[].rules[]|select(.state=="firing")|.name]|join(", ")' <<<"$R" 2>/dev/null)"

echo "== 7) Prueba de alerta real hacia Telegram =="
kubectl -n monitoring exec deploy/alertmanager -- amtool --alertmanager.url=http://localhost:9093 alert add LabPrueba severity=info namespace=monitoring --annotation=summary="Prueba del lab: si ves esto, las alertas llegan a Telegram" >/dev/null 2>&1 \
  && ok "alerta de prueba enviada: debería llegarte a Telegram en ~30 segundos (y 'RESUELTA' en ~5 min)" || bad "no pude enviar la alerta de prueba"

echo "== 8) lab-check vigila los targets, docs y push =="
if ! grep -q 'Métricas (targets)' scripts/lab-check.sh; then
python3 - <<'PY'
import os
p=os.path.expanduser('~/homelab/scripts/lab-check.sh'); s=open(p).read()
blk='''sec "Métricas (targets)"
R=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/victoriametrics:8428/proxy/api/v1/query?query=%28up%3D%3D0%29" 2>/dev/null)
if [ -z "$R" ]; then bad "VictoriaMetrics no responde"; else
  DOWN=$(jq -r '[.data.result[]?|.metric.job]|unique|join(", ")' <<<"$R")
  [ -z "$DOWN" ] && ok "todos los targets responden" || bad "targets caídos: $DOWN"
fi

'''
i=s.index('echo; [ $FAIL'); open(p,'w').write(s[:i]+blk+s[i:])
PY
fi
cat > docs/MONITORING.md <<'MD'
# Monitoreo
- **Recolección:** vmagent (`apps/monitoring/vmagent-config.yaml`) scrapea node-exporter, cAdvisor, kubelet, apiserver, MinIO y los componentes de monitoreo. OTEL Collector sigue recibiendo OTLP y scrapeando kube-state-metrics, cert-manager, ArgoCD, Traefik y pods anotados.
- **Almacenamiento:** VictoriaMetrics (90 días). UI: https://vm.lyxar.dedyn.io (solo LAN).
- **Alertas:** vmalert evalúa `apps/monitoring/configmap-vmalert-rules.yaml` y manda a Alertmanager (https://alertmanager.lyxar.dedyn.io, solo LAN) que notifica por Telegram. El token está cifrado en `sealedsecret-alertmanager-telegram.yaml`.
- **Bot nuevo:** `RESET=1 bash scripts/phase6a-metrics.sh` (pide token y detecta el chat).
- **Silenciar:** en Telegram (silenciar el chat) o en Alertmanager (Silences).
- **Restaurar en un cluster nuevo:** ArgoCD recrea todo desde Git; el token se descifra con la clave de Sealed Secrets.
MD
git add -A; git diff --cached --quiet || git commit -qm "lab-check: vigila targets; docs de monitoreo"
git push -q && ok "push OK"
refresh; sleep 20
kubectl -n argocd get applications.argoproj.io
echo; echo ">>> Mirá tu Telegram: tiene que haber llegado el mensaje de prueba."
