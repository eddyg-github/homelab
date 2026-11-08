#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
D=apps/monitoring; BK=~/homelab-backup
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }
q(){ kubectl get --raw "/api/v1/namespaces/monitoring/services/victoriametrics:8428/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null; }

echo "== 1) platform-velero: adoptar el Secret existente =="
H0=$(kubectl -n velero get secret cloud-credentials -o json | jq -S .data | sha256sum | cut -c1-16)
kubectl -n velero annotate secret cloud-credentials sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null && ok "Secret marcado como adoptable" || bad "no pude anotar el Secret"
kubectl -n velero annotate sealedsecret cloud-credentials lab/reconcile="$(date +%s)" --overwrite >/dev/null
for i in $(seq 1 12); do
  S=$(kubectl -n velero get sealedsecret cloud-credentials -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}'); [ "$S" = True ] && break
  [ $i = 6 ] && kubectl -n kube-system rollout restart deploy/sealed-secrets-controller >/dev/null 2>&1; sleep 10
done
[ "$S" = True ] && ok "SealedSecret sincronizado" || { bad "sigue sin sincronizar:"; kubectl -n velero get sealedsecret cloud-credentials -o jsonpath='{.status.conditions}{"\n"}'; }
H1=$(kubectl -n velero get secret cloud-credentials -o json | jq -S .data | sha256sum | cut -c1-16)
[ "$H0" = "$H1" ] && ok "credenciales de Velero idénticas" || bad "las credenciales cambiaron ($H0 -> $H1)"
refresh; sleep 25
H=$(kubectl -n argocd get application platform-velero -o jsonpath='{.status.health.status}')
[ "$H" = Healthy ] && ok "platform-velero Healthy" || bad "platform-velero sigue $H"
echo "   almacenamiento de backups: $(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}')"

echo "== 2) updn como root con timer de systemd =="
crontab -l > $BK/crontab.bak-$(date +%s) 2>/dev/null && ok "copia del crontab en $BK"
sudo tee /usr/local/bin/updn-run >/dev/null <<'RUN'
#!/bin/bash
# Ejecuta updn como root, registra la salida y publica el resultado como metrica.
OUTDIR=/var/lib/node_exporter/textfile; PROM=$OUTDIR/lab_updn.prom; LOG=/var/log/updn.log
TMP=$(mktemp); NOW=$(date +%s)
{ echo "=== $(date '+%F %T') ==="; DEBIAN_FRONTEND=noninteractive /usr/local/bin/updn; } >"$TMP" 2>&1
RC=$?
cat "$TMP" >> "$LOG"
OK=1
[ $RC -ne 0 ] && OK=0
grep -qE '^(Error:|E: )|sudo: a password|requiere acceso de root' "$TMP" && OK=0
LAST=$(awk '/^lab_updn_last_success_timestamp_seconds/{print $2}' "$PROM" 2>/dev/null)
[ "$OK" = 1 ] && LAST=$NOW
mkdir -p "$OUTDIR"
{ echo "lab_updn_last_run_timestamp_seconds $NOW"; echo "lab_updn_last_run_ok $OK"
  [ -n "${LAST:-}" ] && echo "lab_updn_last_success_timestamp_seconds $LAST"; } > "$PROM.tmp"
chmod 644 "$PROM.tmp"; mv "$PROM.tmp" "$PROM"; rm -f "$TMP"
exit $((1-OK))
RUN
sudo chmod 755 /usr/local/bin/updn-run
sudo tee /etc/systemd/system/lab-updn.service >/dev/null <<'UNIT'
[Unit]
Description=Lab: actualizacion del sistema (updn) como root
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/updn-run
TimeoutStartSec=2h
Nice=10
IOSchedulingClass=idle
UNIT
sudo tee /etc/systemd/system/lab-updn.timer >/dev/null <<'UNIT'
[Unit]
Description=Lab: updn diario a las 05:00
[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true
RandomizedDelaySec=10min
[Install]
WantedBy=timers.target
UNIT
echo '/var/log/updn.log { weekly rotate 8 compress missingok notifempty }' | sudo tee /etc/logrotate.d/updn >/dev/null
sudo systemctl daemon-reload && sudo systemctl enable --now lab-updn.timer >/dev/null 2>&1 && ok "timer lab-updn activo" || bad "no pude activar el timer"
( crontab -l 2>/dev/null | grep -v '/usr/local/bin/updn' ) | crontab - && ok "línea de updn quitada del cron del usuario"

echo "== 3) Reglas de alerta nuevas =="
python3 - <<'PY' || { echo "  ❌ falló la edición"; exit 1; }
import os,yaml,hashlib
D=os.path.expanduser('~/homelab/apps/monitoring/')
class L(str): pass
yaml.add_representer(L,lambda d,s:d.represent_scalar('tag:yaml.org,2002:str',s,style='|'),Dumper=yaml.SafeDumper)
R=lambda a,e,f,sev,s:{'alert':a,'expr':e,'for':f,'labels':{'severity':sev},'annotations':{'summary':s}}
f=D+'configmap-vmalert-rules.yaml'; cm=yaml.safe_load(open(f)); rules=yaml.safe_load(cm['data']['rules.yaml'])
g=[x for x in rules['groups'] if x['name']=='host'][0]
if not any(r.get('alert')=='UpdnFailed' for r in g['rules']):
    g['rules']+=[R('UpdnFailed','lab_updn_last_run_ok == 0','0m','warning','La actualizacion automatica (updn) fallo. Ver: sudo tail -50 /var/log/updn.log'),
                 R('UpdnStale','time() - lab_updn_last_success_timestamp_seconds > 3 * 86400','1h','warning','Hace mas de 3 dias que updn no termina con exito')]
txt=yaml.safe_dump(rules,sort_keys=False,width=200,allow_unicode=True)
cm['data']['rules.yaml']=L(txt); open(f,'w').write(yaml.safe_dump(cm,sort_keys=False,width=200,allow_unicode=True))
f=D+'deployment-vmalert.yaml'; o=yaml.safe_load(open(f))
o['spec']['template'].setdefault('metadata',{}).setdefault('annotations',{})['checksum/rules']=hashlib.sha256(txt.encode()).hexdigest()[:12]
open(f,'w').write(yaml.safe_dump(o,sort_keys=False,width=200))
PY
kubectl apply --dry-run=server -f $D/ >/tmp/dry6d.txt 2>&1 && ok "manifiestos válidos" || { head -10 /tmp/dry6d.txt; bad "dry-run falló, no se publica"; exit 1; }
cat >> docs/HOST.md <<'MD'
- **updn:** `lab-updn.timer` (systemd, root, diario 05:00) ejecuta `/usr/local/bin/updn-run`, que llama a `/usr/local/bin/updn`, guarda el log en `/var/log/updn.log` y publica `lab_updn_*`. Alertas `UpdnFailed` y `UpdnStale`. Como el recolector, vive en el servidor y no en Git: recrearlo con `scripts/phase6d-fixes.sh`.
MD
git add -A; git diff --cached --quiet || git commit -qm "monitoring: alertas de updn; docs"
git push -q && ok "push OK" || bad "push falló"
refresh

echo "== 4) Primera ejecución de updn (puede tardar varios minutos) =="
sudo systemctl start lab-updn.service; RC=$?
[ $RC = 0 ] && ok "updn terminó sin errores" || { bad "updn reportó fallo. Últimas líneas del log:"; sudo tail -25 /var/log/updn.log; }
echo "   reinicio requerido: $([ -f /var/run/reboot-required ] && echo SÍ || echo no)"
echo "   LocalStack: $(docker ps --format '{{.Names}} {{.Status}}' | head -3)"
echo "   k3s: $(systemctl is-active k3s)   nodo: $(kubectl get nodes --no-headers | awk '{print $2}')"
cat /var/lib/node_exporter/textfile/lab_updn.prom | sed 's/^/   /'
systemctl list-timers --no-pager | grep -E 'lab-|NEXT' | sed 's/^/   /'
echo "   cron del usuario: $(crontab -l 2>/dev/null | grep -c updn) líneas de updn"

echo "== 5) Esperando reglas nuevas =="
for i in $(seq 1 30); do kubectl -n monitoring get cm vmalert-rules -o jsonpath='{.data.rules\.yaml}' | grep -q UpdnFailed && break; refresh; sleep 10; done
kubectl -n monitoring rollout status deploy/vmalert --timeout=240s >/dev/null 2>&1 && ok "vmalert con las reglas de updn" || bad "vmalert no Ready"
sleep 20
R=$(kubectl get --raw /api/v1/namespaces/monitoring/services/vmalert:8880/proxy/api/v1/rules 2>/dev/null)
echo "   reglas: $(jq -r '[.data.groups[].rules[]]|length' <<<"$R")   con error: $(jq -r '[.data.groups[].rules[]|select((.lastError//"")!="")|.name]|join(", ")' <<<"$R")"
kubectl -n argocd get applications.argoproj.io
