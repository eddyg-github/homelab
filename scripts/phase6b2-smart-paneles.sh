#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }; warn(){ echo "  ⚠️  $*"; }
cd ~/homelab || exit 1
SRC=grafana/dashboards-src; CM=apps/monitoring/configmap-grafana-dashboards.yaml; J=$SRC/servidor-discos.json

echo "== 0) Pre-chequeos =="
[ -s "$J" ] && ok "$J existe" || { bad "falta $J (corré primero phase6b)"; exit 1; }
cp "$CM" ~/homelab-backup/configmap-grafana-dashboards.yaml.bak2 && cp "$J" ~/homelab-backup/servidor-discos.json.bak && ok "backups"

echo "== 1) Agregando paneles SMART =="
python3 - <<'PYEOF'
import json
p = "grafana/dashboards-src/servidor-discos.json"
d = json.load(open(p))
nuevos = ["Sectores pendientes", "Errores CRC acumulados", "Errores CRC nuevos en 24 h"]
d["panels"] = [x for x in d["panels"] if x["title"] not in nuevos]
nid = max(x["id"] for x in d["panels"]) + 1
def steps(*pairs):
    out = [{"color": pairs[0][0], "value": None}]
    for c, v in pairs[1:]: out.append({"color": c, "value": v})
    return out
def stat(title, expr, x, th, desc):
    global nid
    pn = {"id": nid, "type": "stat", "title": title, "description": desc,
          "gridPos": {"x": x, "y": 28, "w": 8, "h": 6},
          "targets": [{"expr": expr, "refId": "A", "legendFormat": "{{device}}", "instant": True}],
          "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": th}, "color": {"mode": "thresholds"}, "decimals": 0}, "overrides": []},
          "options": {"colorMode": "background", "textMode": "value_and_name", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}}}
    nid += 1
    return pn
G, O, R = "green", "orange", "red"
d["panels"] += [
  stat("Sectores pendientes", 'lab_smart_attribute_raw{name="current_pending_sector"}', 0, steps((G, None), (O, 1), (R, 5)),
       "Sectores que el disco no pudo leer y espera reubicar. Cualquier valor mayor a 0 conviene vigilarlo (sdd tiene 1)."),
  stat("Errores CRC acumulados", 'lab_smart_attribute_raw{name="udma_crc_error_count"}', 8, steps((G, None), (O, 1)),
       "Contador de por vida: un número alto no significa problema activo. Mirá el panel de 24 h. Suele ser cable SATA."),
  stat("Errores CRC nuevos en 24 h", 'delta(lab_smart_attribute_raw{name="udma_crc_error_count"}[24h])', 16, steps((G, None), (R, 1)),
       "Si es mayor a 0, el cable o puerto SATA sigue dando errores ahora."),
]
for x in d["panels"]:
    if x["title"] == "SMART: atributos crudos":
        x["gridPos"] = {"x": 0, "y": 34, "w": 24, "h": 8}
d["version"] = d.get("version", 1) + 1
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
PYEOF
jq -e '.panels|length' "$J" >/dev/null 2>&1 && ok "JSON válido ($(jq '.panels|length' $J) paneles)" || { bad "JSON inválido"; exit 1; }

echo "== 2) ConfigMap =="
kubectl create configmap grafana-dashboards -n monitoring --from-file="$SRC" --dry-run=client -o yaml > "$CM" || { bad "no pude generar el ConfigMap"; exit 1; }
kubectl apply --dry-run=server -f "$CM" >/dev/null 2>&1 && ok "ConfigMap válido para el cluster" || { bad "el cluster lo rechazó"; cp ~/homelab-backup/configmap-grafana-dashboards.yaml.bak2 "$CM"; exit 1; }

echo "== 3) Consultas nuevas contra VictoriaMetrics =="
kubectl -n monitoring port-forward svc/victoriametrics 18428:8428 >/tmp/pf.log 2>&1 &
PF=$!; sleep 4; VM=http://127.0.0.1:18428
for q in 'lab_smart_attribute_raw{name="current_pending_sector"}' 'lab_smart_attribute_raw{name="udma_crc_error_count"}' 'delta(lab_smart_attribute_raw{name="udma_crc_error_count"}[24h])'; do
  R=$(curl -s "$VM/api/v1/query" --data-urlencode "query=$q" | jq -r '.data.result[] | "\(.metric.device)=\(.value[1])"' | tr '\n' ' ')
  [ -n "$R" ] && ok "${q:0:62} -> $R" || warn "SIN DATOS: $q"
done
kill $PF 2>/dev/null

echo "== 4) Commit, push y ArgoCD =="
git add grafana/ "$CM" scripts/phase6b2-smart-paneles.sh
git commit -qm "grafana: paneles SMART (pendientes, CRC acumulado y nuevo)" && git push -q && ok "push OK" || { bad "falló el push"; exit 1; }
kubectl -n argocd annotate application app-monitoring argocd.argoproj.io/refresh=hard --overwrite >/dev/null
HEAD=$(git rev-parse HEAD); synced=0
for i in $(seq 1 24); do
  S=$(kubectl -n argocd get application app-monitoring -o jsonpath='{.status.sync.status} {.status.sync.revision}')
  [ "$S" = "Synced $HEAD" ] && { synced=1; break; }; sleep 5
done
[ $synced = 1 ] && ok "ArgoCD Synced" || bad "ArgoCD no llegó a Synced (estado: $S)"

echo "== 5) ¿Llegó el cambio a Grafana? (hasta ~2 min) =="
found=0
for i in $(seq 1 30); do
  kubectl -n monitoring exec deploy/grafana -- grep -c "Errores CRC nuevos" /var/lib/grafana/dashboards/servidor-discos.json 2>/dev/null | grep -q '^[1-9]' && { found=1; break; }; sleep 5
done
[ $found = 1 ] && ok "dashboard actualizado en el pod" || bad "el pod todavía tiene la versión vieja"
echo; echo ">>> Recargá 'Servidor y discos' en Grafana (abajo de todo están los paneles nuevos)."
