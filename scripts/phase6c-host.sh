#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
D=apps/monitoring; OUT=/var/lib/node_exporter/textfile/lab_host.prom
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }
q(){ kubectl get --raw "/api/v1/namespaces/monitoring/services/victoriametrics:8428/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null; }

echo "== 0) Pre-chequeos =="
for c in smartctl docker python3; do command -v $c >/dev/null && ok "$c" || bad "falta $c (sigo igual)"; done
for f in $D/node-exporter.yaml $D/configmap-vmalert-rules.yaml $D/deployment-vmalert.yaml; do [ -s $f ] && ok "$f" || { bad "falta $f"; exit 1; }; done

echo "== 1) Recolector de métricas del host =="
sudo tee /usr/local/bin/lab-host-metrics >/dev/null <<'PYEOF'
#!/usr/bin/env python3
import os, re, subprocess, time, json, glob, shutil, urllib.request
OUT_DIR = "/var/lib/node_exporter/textfile"
OUT = OUT_DIR + "/lab_host.prom"
SLOW = OUT_DIR + "/.slow.cache"
U = {"B":1,"KB":1e3,"MB":1e6,"GB":1e9,"TB":1e12,"KIB":1024,"MIB":1024**2,"GIB":1024**3,"TIB":1024**4}
NAMES = {5:"reallocated_sector_ct",9:"power_on_hours",187:"reported_uncorrect",194:"temperature_celsius",
         197:"current_pending_sector",198:"offline_uncorrectable",199:"udma_crc_error_count"}

def run(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:
        return 127, "", str(e)

def esc(v): return str(v).replace("\\", "\\\\").replace('"', '\\"')
def fmt(_m, _v, **labels):
    l = ",".join('%s="%s"' % (k, esc(v)) for k, v in labels.items())
    return "%s%s %s" % (_m, "{" + l + "}" if l else "", _v)
def tobytes(s):
    m = re.match(r"\s*([\d.]+)\s*([A-Za-z]+)", s)
    return int(float(m.group(1)) * U.get(m.group(2).upper(), 1)) if m else 0

L = []
# --- SMART (sin despertar discos dormidos)
for dev in sorted(glob.glob("/dev/sd?")):
    n = os.path.basename(dev)
    rc, out, err = run(["smartctl", "-n", "standby", "-H", "-A", dev])
    if "STANDBY" in (out + err).upper():
        L.append(fmt("lab_smart_standby", 1, device=n)); continue
    if "SMART overall-health" not in out:
        L.append(fmt("lab_smart_readable", 0, device=n)); continue
    L.append(fmt("lab_smart_readable", 1, device=n))
    L.append(fmt("lab_smart_passed", 1 if "PASSED" in out else 0, device=n))
    for ln in out.splitlines():
        p = ln.split()
        if len(p) >= 10 and p[0].isdigit() and int(p[0]) in NAMES:
            m = re.match(r"\d+", p[9])
            if m: L.append(fmt("lab_smart_attribute_raw", m.group(0), device=n, name=NAMES[int(p[0])]))

# --- Sistema
L.append(fmt("lab_reboot_required", 1 if os.path.exists("/var/run/reboot-required") else 0))
rc, out, _ = run(["systemctl", "--failed", "--no-legend", "--plain"], 20)
failed = [l.split()[0] for l in out.splitlines() if l.strip()]
L.append(fmt("lab_systemd_failed_units", len(failed)))
for u in failed: L.append(fmt("lab_systemd_unit_failed", 1, unit=u))

# --- Docker
rc, out, _ = run(["docker", "ps", "-a", "--format", "{{.Names}}|{{.State}}"], 20)
if rc == 0:
    L.append(fmt("lab_docker_up", 1))
    for l in out.splitlines():
        name, _, st = l.partition("|")
        L.append(fmt("lab_docker_container_running", 1 if st == "running" else 0, name=name))
    rc2, out2, _ = run(["docker", "stats", "--no-stream", "--format", "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}"], 60)
    if rc2 == 0:
        for l in out2.splitlines():
            try:
                name, cpu, mem = l.split("|")
                L.append(fmt("lab_docker_container_cpu_percent", float(cpu.strip().rstrip("%")), name=name))
                L.append(fmt("lab_docker_container_memory_bytes", tobytes(mem.split("/")[0]), name=name))
            except Exception: pass
else:
    L.append(fmt("lab_docker_up", 0))

# --- LocalStack
try:
    with urllib.request.urlopen("http://127.0.0.1:4566/_localstack/health", timeout=5) as r:
        h = json.load(r)
    L.append(fmt("lab_localstack_up", 1))
    for s, st in h.get("services", {}).items():
        L.append(fmt("lab_localstack_service_running", 1 if st == "running" else 0, service=s))
except Exception:
    L.append(fmt("lab_localstack_up", 0))

# --- Bloque lento (cada 6 h): apt, snap, flatpak
os.makedirs(OUT_DIR, exist_ok=True); os.chmod(OUT_DIR, 0o755)
if os.path.exists(SLOW) and time.time() - os.path.getmtime(SLOW) < 6 * 3600:
    S = open(SLOW).read().splitlines()
else:
    S = []
    rc, _, _ = run(["apt-get", "update", "-qq"], 300)
    S.append(fmt("lab_apt_update_ok", 1 if rc == 0 else 0))
    rc, out, _ = run(["apt-get", "-s", "dist-upgrade"], 120)
    inst = [l for l in out.splitlines() if l.startswith("Inst ")]
    S.append(fmt("lab_pending_updates", len(inst), source="apt"))
    S.append(fmt("lab_pending_security_updates", len([l for l in inst if "security" in l.lower()]), source="apt"))
    if shutil.which("snap"):
        rc, out, _ = run(["snap", "refresh", "--list"], 60)
        if rc == 0: S.append(fmt("lab_pending_updates", len([l for l in out.splitlines()[1:] if l.strip()]), source="snap"))
    if shutil.which("flatpak"):
        rc, out, _ = run(["flatpak", "remote-ls", "--updates"], 120)
        if rc == 0: S.append(fmt("lab_pending_updates", len([l for l in out.splitlines() if l.strip()]), source="flatpak"))
    open(SLOW, "w").write("\n".join(S) + "\n")

L.append(fmt("lab_host_metrics_timestamp_seconds", int(time.time())))
tmp = OUT + ".tmp"
open(tmp, "w").write("\n".join(L + S) + "\n")
os.chmod(tmp, 0o644); os.replace(tmp, OUT)
PYEOF
sudo chmod 755 /usr/local/bin/lab-host-metrics
sudo tee /etc/systemd/system/lab-host-metrics.service >/dev/null <<'UNIT'
[Unit]
Description=Lab: metricas del host para node-exporter
[Service]
Type=oneshot
ExecStart=/usr/local/bin/lab-host-metrics
Nice=10
IOSchedulingClass=idle
UNIT
sudo tee /etc/systemd/system/lab-host-metrics.timer >/dev/null <<'UNIT'
[Unit]
Description=Lab: metricas del host cada 5 minutos
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now lab-host-metrics.timer >/dev/null 2>&1 && ok "timer activo (cada 5 min)" || bad "no pude activar el timer"
echo "   primera ejecución (apt-get update puede tardar un minuto)..."
sudo systemctl start lab-host-metrics.service
[ -s $OUT ] && ok "$(grep -c . $OUT) métricas en $OUT" || { bad "no se generó $OUT"; sudo journalctl -u lab-host-metrics -n 15 --no-pager; exit 1; }
grep -E 'passed|pending_sector|crc|pending_updates|reboot|failed_units|docker_up|localstack_up|apt_update' $OUT | sed 's/^/   /'

echo "== 2) Manifiestos: node-exporter lee el archivo + reglas de alerta =="
python3 - <<'PY' || { echo "  ❌ falló la edición"; exit 1; }
import os,yaml,hashlib
D=os.path.expanduser('~/homelab/apps/monitoring/')
class L(str): pass
yaml.add_representer(L,lambda d,s:d.represent_scalar('tag:yaml.org,2002:str',s,style='|'),Dumper=yaml.SafeDumper)
hs=lambda s:hashlib.sha256(s.encode()).hexdigest()[:12]
f=D+'node-exporter.yaml'; docs=list(yaml.safe_load_all(open(f)))
for d in docs:
    if d['kind']=='DaemonSet':
        a=d['spec']['template']['spec']['containers'][0]['args']
        if not any('textfile' in x for x in a): a.append('--collector.textfile.directory=/host/root/var/lib/node_exporter/textfile')
yaml.safe_dump_all(docs,open(f,'w'),sort_keys=False,width=200)
R=lambda a,e,f,sev,s:{'alert':a,'expr':e,'for':f,'labels':{'severity':sev},'annotations':{'summary':s}}
f=D+'configmap-vmalert-rules.yaml'; cm=yaml.safe_load(open(f)); rules=yaml.safe_load(cm['data']['rules.yaml'])
if not any(g['name']=='host' for g in rules['groups']):
    rules['groups'].append({'name':'host','interval':'60s','rules':[
      R('SmartFailing','lab_smart_passed == 0','0m','critical','SMART reporta FALLA en el disco {{ $labels.device }}: hacer backup ya'),
      R('SmartPendingSector','lab_smart_attribute_raw{name="current_pending_sector"} > 0','10m','warning','Disco {{ $labels.device }}: {{ $value }} sector(es) pendientes de reasignar (posible inicio de falla)'),
      R('SmartBadSectors','lab_smart_attribute_raw{name=~"reallocated_sector_ct|offline_uncorrectable|reported_uncorrect"} > 0','10m','warning','Disco {{ $labels.device }}: {{ $labels.name }} = {{ $value }}'),
      R('SmartCRCGrowing','increase(lab_smart_attribute_raw{name="udma_crc_error_count"}[1h]) > 0','0m','warning','Disco {{ $labels.device }} sigue sumando errores CRC: revisar cable SATA o puerto'),
      R('DiskTemperature','lab_smart_attribute_raw{name="temperature_celsius"} > 55','10m','warning','Disco {{ $labels.device }} a {{ $value }} C'),
      R('PendingUpdates','lab_pending_updates > 0','1h','info','{{ $value }} actualizacion(es) pendiente(s) de {{ $labels.source }}. Aplicar a mano: sudo /usr/local/bin/updn'),
      R('PendingSecurityUpdates','lab_pending_security_updates > 0','1h','warning','{{ $value }} actualizacion(es) de SEGURIDAD pendiente(s) en apt'),
      R('RebootRequired','lab_reboot_required == 1','1h','warning','El servidor necesita reiniciarse por una actualizacion'),
      R('SystemdUnitsFailed','lab_systemd_failed_units > 0','10m','warning','{{ $value }} servicio(s) de systemd fallido(s) en el host (systemctl --failed)'),
      R('AptUpdateFailing','lab_apt_update_ok == 0','1h','warning','apt-get update falla: no se pueden detectar actualizaciones'),
      R('HostCollectorStale','time() - lab_host_metrics_timestamp_seconds > 1800','0m','warning','El recolector de metricas del host dejo de actualizar (systemctl status lab-host-metrics.timer)'),
      R('DockerDown','lab_docker_up == 0','5m','critical','El demonio Docker no responde'),
      R('DockerContainerStopped','lab_docker_container_running == 0','5m','warning','El contenedor Docker {{ $labels.name }} no esta corriendo'),
      R('LocalstackDown','lab_localstack_up == 0','10m','warning','LocalStack no responde en el puerto 4566 (si lo apagaste a proposito, silenciar esta alerta)'),
      R('HighIOPressure','rate(node_pressure_io_stalled_seconds_total[5m]) > 0.25','15m','warning','I/O: procesos detenidos esperando disco el {{ $value | humanizePercentage }} del tiempo'),
      R('HighMemoryPressure','rate(node_pressure_memory_stalled_seconds_total[5m]) > 0.10','10m','warning','Memoria: procesos detenidos por falta de RAM el {{ $value | humanizePercentage }} del tiempo')]})
txt=yaml.safe_dump(rules,sort_keys=False,width=200,allow_unicode=True)
cm['data']['rules.yaml']=L(txt); open(f,'w').write(yaml.safe_dump(cm,sort_keys=False,width=200,allow_unicode=True))
f=D+'deployment-vmalert.yaml'; o=yaml.safe_load(open(f))
o['spec']['template'].setdefault('metadata',{}).setdefault('annotations',{})['checksum/rules']=hs(txt)
open(f,'w').write(yaml.safe_dump(o,sort_keys=False,width=200))
print('  reglas totales:',sum(len(g['rules']) for g in rules['groups']))
PY
ok "manifiestos editados"

echo "== 3) Revierto el filtro erróneo del lab-check =="
python3 - <<'PY'
import os
p=os.path.expanduser('~/homelab/scripts/lab-check.sh'); s=open(p).read()
bad='query=%28up%3D%3D0%20and%20on%28job%2Cinstance%29%20last_over_time%28up%5B5m%5D%29%3E-1%29'
print('  revertido' if bad in s else '  (ya estaba bien)'); open(p,'w').write(s.replace(bad,'query=%28up%3D%3D0%29'))
PY

echo "== 4) Dry-run, docs y push =="
kubectl apply --dry-run=server -f $D/ >/tmp/dry6c.txt 2>&1 && ok "manifiestos válidos" || { head -15 /tmp/dry6c.txt; bad "dry-run falló, no se publica"; exit 1; }
cat > docs/HOST.md <<'MD'
# Métricas del host
- `/usr/local/bin/lab-host-metrics` (root, timer systemd cada 5 min) escribe `/var/lib/node_exporter/textfile/lab_host.prom`; node-exporter lo lee.
- Mide: SMART de los discos, paquetes pendientes (apt/snap/flatpak), reinicio requerido, unidades systemd fallidas, contenedores Docker y LocalStack.
- Las alertas están en el grupo `host` de `apps/monitoring/configmap-vmalert-rules.yaml`.
- El script y los units NO viven en Git de forma automática: en un servidor nuevo, volver a correr `scripts/phase6c-host.sh`.
- Actualizar a mano cuando llegue el aviso: `sudo /usr/local/bin/updn` (puede actualizar kernel/containerd; hacerlo con calma).
MD
git add -A; git diff --cached --quiet || git commit -qm "monitoring: metricas del host (SMART, updates, docker, localstack), alertas, lab-check corregido"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh
for i in $(seq 1 30); do kubectl -n monitoring get ds node-exporter -o json | jq -e '.spec.template.spec.containers[0].args|any(test("textfile"))' >/dev/null && break; refresh; sleep 10; done
kubectl -n monitoring rollout status ds/node-exporter --timeout=240s >/dev/null 2>&1 && ok "node-exporter con textfile" || bad "node-exporter no Ready"
for i in $(seq 1 30); do kubectl -n monitoring get cm vmalert-rules -o jsonpath='{.data.rules\.yaml}' | grep -q SmartFailing && break; refresh; sleep 10; done
kubectl -n monitoring rollout status deploy/vmalert --timeout=240s >/dev/null 2>&1 && ok "vmalert con las reglas nuevas" || bad "vmalert no Ready"

echo "== 5) Verificación (máx 5 min) =="
for i in $(seq 1 30); do N=$(q 'count(lab_host_metrics_timestamp_seconds)' | jq -r '.data.result[0].value[1] // 0'); [ "${N:-0}" -ge 1 ] && break; sleep 10; done
[ "${N:-0}" -ge 1 ] && ok "las métricas del host llegan a VictoriaMetrics" || bad "no llegan todavía (puede tardar un minuto más)"
echo "   SMART:"; q 'lab_smart_attribute_raw{name=~"current_pending_sector|udma_crc_error_count|reallocated_sector_ct|temperature_celsius"}' | jq -r '.data.result[]|"     \(.metric.device)  \(.metric.name) = \(.value[1])"' | sort
echo "   paquetes pendientes:"; q 'lab_pending_updates' | jq -r '.data.result[]|"     \(.metric.source) = \(.value[1])"'
echo "   docker:"; q 'lab_docker_container_running' | jq -r '.data.result[]|"     \(.metric.name) running=\(.value[1])"'
echo "   localstack up = $(q 'lab_localstack_up' | jq -r '.data.result[0].value[1] // "sin dato"')"
echo "   presión de I/O (fracción del tiempo, 5 min) = $(q 'rate(node_pressure_io_stalled_seconds_total[5m])' | jq -r '.data.result[0].value[1] // "sin dato"')"
R=$(kubectl get --raw /api/v1/namespaces/monitoring/services/vmalert:8880/proxy/api/v1/rules 2>/dev/null)
echo "   reglas: $(jq -r '[.data.groups[].rules[]]|length' <<<"$R")   con error: $(jq -r '[.data.groups[].rules[]|select((.lastError//"")!="")|.name]|join(", ")' <<<"$R")"
kubectl -n argocd get applications.argoproj.io
