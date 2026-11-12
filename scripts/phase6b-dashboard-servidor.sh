#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }; warn(){ echo "  ⚠️  $*"; }
cd ~/homelab || exit 1
SRC=grafana/dashboards-src
CM=apps/monitoring/configmap-grafana-dashboards.yaml

echo "== 0) Pre-chequeos =="
command -v python3 >/dev/null && ok "python3" || { bad "falta python3"; exit 1; }
command -v jq >/dev/null && ok "jq" || { bad "falta jq"; exit 1; }
kubectl -n argocd get application app-monitoring >/dev/null 2>&1 && ok "ArgoCD app-monitoring" || { bad "no existe la app app-monitoring"; exit 1; }
[ -f "$CM" ] && ok "$CM existe" || { bad "falta $CM"; exit 1; }

echo "== 1) Fuentes de los dashboards (fuera de apps/) =="
mkdir -p "$SRC"
cp "$CM" ~/homelab-backup/configmap-grafana-dashboards.yaml.bak && ok "backup del ConfigMap anterior"
if [ ! -s "$SRC/cluster-overview.json" ]; then
  kubectl -n monitoring get cm grafana-dashboards -o json | jq -r '.data["cluster-overview.json"]' > "$SRC/cluster-overview.json"
fi
jq -e . "$SRC/cluster-overview.json" >/dev/null 2>&1 && ok "cluster-overview.json conservado" || { bad "no pude extraer cluster-overview.json"; exit 1; }

echo "== 2) Generando servidor-discos.json =="
python3 - <<'PYEOF'
import json
pid = [0]
def nid():
    pid[0] += 1
    return pid[0]

def target(expr, legend=None, instant=False, fmt=None):
    t = {"expr": expr, "refId": chr(65 + target.n)}
    target.n += 1
    if legend is not None: t["legendFormat"] = legend
    if instant: t["instant"] = True
    if fmt: t["format"] = fmt
    return t
target.n = 0

def panel(ptype, title, targets, x, y, w, h, unit=None, desc="", thresholds=None, mappings=None, options=None, minv=None, maxv=None, transformations=None):
    target.n = 0
    ts = []
    for t in targets:
        ts.append(target(*t) if isinstance(t, tuple) else target(**t))
        target.n = len(ts)
    defaults = {}
    if unit: defaults["unit"] = unit
    if minv is not None: defaults["min"] = minv
    if maxv is not None: defaults["max"] = maxv
    if thresholds:
        defaults["thresholds"] = {"mode": "absolute", "steps": thresholds}
        defaults["color"] = {"mode": "thresholds"}
    if mappings: defaults["mappings"] = mappings
    p = {"id": nid(), "type": ptype, "title": title, "description": desc,
         "gridPos": {"x": x, "y": y, "w": w, "h": h},
         "targets": ts, "fieldConfig": {"defaults": defaults, "overrides": []}}
    if options: p["options"] = options
    if transformations: p["transformations"] = transformations
    return p

G, O, R = "green", "orange", "red"
def steps(*pairs):
    out = [{"color": pairs[0][0], "value": None}]
    for c, v in pairs[1:]: out.append({"color": c, "value": v})
    return out

DISK = 'device=~"sd[a-d]"'
panels = []

# Fila 1: estado general
panels.append(panel("stat", "SMART por disco", [("lab_smart_passed", "{{device}}")], 0, 0, 8, 4,
    desc="Resultado general de SMART por disco. Se asume 1 = pasó, 0 = falló.",
    thresholds=steps((R, None), (G, 1)),
    mappings=[{"type": "value", "options": {"0": {"text": "FALLA", "color": "red"}, "1": {"text": "OK", "color": "green"}}}],
    options={"colorMode": "background", "textMode": "value_and_name", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}}))
panels.append(panel("stat", "Temperatura máx. (hwmon)", [("max(node_hwmon_temp_celsius)",)], 8, 0, 4, 4, unit="celsius",
    thresholds=steps((G, None), (O, 55), (R, 70)), options={"reduceOptions": {"calcs": ["lastNotNull"]}}))
panels.append(panel("stat", "Memoria disponible", [("node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100",)], 12, 0, 4, 4, unit="percent",
    thresholds=steps((R, None), (O, 10), (G, 20)), options={"reduceOptions": {"calcs": ["lastNotNull"]}}))
panels.append(panel("stat", "Carga (load 1m)", [("node_load1",)], 16, 0, 4, 4,
    desc="Referencia: el equipo tiene 4 núcleos.", thresholds=steps((G, None), (O, 4), (R, 8)), options={"reduceOptions": {"calcs": ["lastNotNull"]}}))
panels.append(panel("stat", "Pendientes / fallos", [("lab_pending_updates", "actualizaciones pendientes"), ("lab_systemd_failed_units", "units fallidas"), ("lab_reboot_required", "reinicio requerido")], 20, 0, 4, 4,
    options={"colorMode": "none", "textMode": "value_and_name", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}}))

# Fila 2: I/O
panels.append(panel("timeseries", "Lectura por disco", [(f'rate(node_disk_read_bytes_total{{{DISK}}}[$__rate_interval])', "{{device}}")], 0, 4, 8, 8, unit="Bps"))
panels.append(panel("timeseries", "Escritura por disco", [(f'rate(node_disk_written_bytes_total{{{DISK}}}[$__rate_interval])', "{{device}}")], 8, 4, 8, 8, unit="Bps"))
panels.append(panel("timeseries", "Utilización de cada disco (%)", [(f'rate(node_disk_io_time_seconds_total{{{DISK}}}[$__rate_interval]) * 100', "{{device}}")], 16, 4, 8, 8, unit="percent", minv=0, maxv=100,
    desc="Porcentaje del tiempo que el disco estuvo ocupado. Cerca de 100 = disco saturado."))

# Fila 3: presión y espacio
panels.append(panel("timeseries", "Presión PSI (% del tiempo detenido o esperando)", [
    ("rate(node_pressure_io_stalled_seconds_total[$__rate_interval]) * 100", "I/O detenido"),
    ("rate(node_pressure_io_waiting_seconds_total[$__rate_interval]) * 100", "I/O esperando"),
    ("rate(node_pressure_cpu_waiting_seconds_total[$__rate_interval]) * 100", "CPU esperando"),
    ("rate(node_pressure_memory_stalled_seconds_total[$__rate_interval]) * 100", "Memoria detenida")], 0, 12, 12, 8, unit="percent", minv=0,
    desc="PSI del kernel. I/O detenido sostenido por encima de 10-20% indica discos saturados."))
panels.append(panel("bargauge", "Espacio libre por montaje", [('node_filesystem_avail_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"}', "{{mountpoint}}")], 12, 12, 12, 8, unit="bytes",
    thresholds=steps((R, None), (O, 20 * 1024**3), (G, 50 * 1024**3)),
    options={"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"]}},
    desc="Rojo por debajo de 20 GB libres, verde por encima de 50 GB. lab-check usa 20 GB como mínimo."))

# Fila 4: temperaturas y SMART crudo
panels.append(panel("timeseries", "Temperaturas (hwmon)", [("node_hwmon_temp_celsius",)], 0, 20, 12, 8, unit="celsius"))
panels.append(panel("table", "SMART: atributos crudos", [{"expr": "lab_smart_attribute_raw", "instant": True, "fmt": "table"}], 12, 20, 12, 8,
    desc="Todos los atributos tal como los exporta lab-host-metrics. Se afinará a los críticos (sector pendiente, CRC).",
    options={"showHeader": True, "sortBy": [{"displayName": "Value", "desc": True}]},
    transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True, "__name__": True, "job": True, "instance": True}}}]))

dash = {"title": "Servidor y discos", "uid": "servidor-discos", "schemaVersion": 39, "version": 1,
        "editable": True, "refresh": "30s", "time": {"from": "now-6h", "to": "now"},
        "tags": ["host", "discos"], "panels": panels}
json.dump(dash, open("grafana/dashboards-src/servidor-discos.json", "w"), indent=2, ensure_ascii=False)
print("ok")
PYEOF
jq -e '.panels|length' "$SRC/servidor-discos.json" >/dev/null 2>&1 && ok "JSON válido ($(jq '.panels|length' $SRC/servidor-discos.json) paneles)" || { bad "JSON inválido"; exit 1; }

echo "== 3) Regenerando el ConfigMap =="
kubectl create configmap grafana-dashboards -n monitoring --from-file="$SRC" --dry-run=client -o yaml > /tmp/cm-new.yaml || { bad "no pude generar el ConfigMap"; exit 1; }
cp /tmp/cm-new.yaml "$CM"
kubectl apply --dry-run=server -f "$CM" >/dev/null 2>&1 && ok "ConfigMap válido para el cluster" || { bad "el cluster rechazó el ConfigMap"; cp ~/homelab-backup/configmap-grafana-dashboards.yaml.bak "$CM"; exit 1; }
grep -qiE 'password|secret|token' "$SRC"/*.json && { bad "posible secreto en los JSON"; exit 1; } || ok "sin secretos en los JSON"

echo "== 4) Validando cada consulta contra VictoriaMetrics =="
kubectl -n monitoring port-forward svc/victoriametrics 18428:8428 >/tmp/pf.log 2>&1 &
PF=$!; sleep 4
VM=http://127.0.0.1:18428
jq -r '.panels[].targets[].expr' "$SRC/servidor-discos.json" | sed 's/\$__rate_interval/5m/g' | sort -u | while read -r q; do
  n=$(curl -s "$VM/api/v1/query" --data-urlencode "query=$q" | jq '.data.result|length' 2>/dev/null)
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then ok "$n series: ${q:0:70}"; else warn "SIN DATOS: ${q:0:70}"; fi
done
kill $PF 2>/dev/null

echo "== 5) Commit, push y ArgoCD =="
git add grafana/ "$CM" scripts/phase6b-dashboard-servidor.sh
git commit -qm "grafana: dashboard Servidor y discos (como código)" && git push -q && ok "push OK" || { bad "falló el push"; exit 1; }
kubectl -n argocd annotate application app-monitoring argocd.argoproj.io/refresh=hard --overwrite >/dev/null
HEAD=$(git rev-parse HEAD); synced=0
for i in $(seq 1 24); do
  S=$(kubectl -n argocd get application app-monitoring -o jsonpath='{.status.sync.status} {.status.sync.revision}')
  [ "$S" = "Synced $HEAD" ] && { synced=1; break; }; sleep 5
done
[ $synced = 1 ] && ok "ArgoCD Synced en $HEAD" || bad "ArgoCD no llegó a Synced en 2 min (estado: $S)"

echo "== 6) ¿Grafana lo cargó? (el volumen tarda hasta ~1-2 min) =="
found=0
for i in $(seq 1 30); do
  kubectl -n monitoring exec deploy/grafana -- ls /var/lib/grafana/dashboards 2>/dev/null | grep -q servidor-discos.json && { found=1; break; }; sleep 5
done
[ $found = 1 ] && ok "archivo presente en el pod de Grafana" || bad "el archivo no apareció en Grafana"
kubectl -n monitoring logs deploy/grafana --since=5m 2>&1 | grep -iE 'level=error.*dashboard|failed to load dashboard' | head -3 | sed 's/^/   /'
echo
echo ">>> Abrí Grafana (LAN/VPN) -> Dashboards -> 'Servidor y discos' y contame qué ves."
