#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }; warn(){ echo "  ⚠️  $*"; }
cd ~/homelab || exit 1
SRC=grafana/dashboards-src; GEN=grafana/gen; CM=apps/monitoring/configmap-grafana-dashboards.yaml
NEW="k3s-pods sparky-home servidor-discos docker-localstack plataforma apps-media guacamole"

echo "== 0) Pre-chequeos =="
for c in python3 jq kubectl curl git md5sum sed; do command -v $c >/dev/null && ok "$c" || { bad "falta $c"; exit 1; }; done
kubectl -n argocd get application app-monitoring >/dev/null 2>&1 && ok "ArgoCD app-monitoring" || { bad "no existe app-monitoring"; exit 1; }
[ -s "$GEN/dashlib2.py" ] && ok "estilo base (dashlib2) presente" || warn "no estaba dashlib2.py: se vuelve a crear"
mkdir -p "$GEN" "$SRC" ~/homelab-backup
cp "$CM" ~/homelab-backup/configmap-grafana-dashboards.yaml.bak5 && rm -rf ~/homelab-backup/dashboards-src.bak5 && cp -r "$SRC" ~/homelab-backup/dashboards-src.bak5 && ok "backup del ConfigMap y de dashboards-src"

echo "== 1) Generadores de dashboards (versionados en Git) =="
cat > "$GEN/dashlib2.py" <<'PYLIB2'
"""Librería de dashboards Grafana con tema oscuro/neón y autolayout.
Solo usa paneles nativos de Grafana 10.4 (sin plugins)."""
import json

C = {"cyan": "#22D3EE", "violet": "#A78BFA", "pink": "#F472B6", "green": "#34D399",
     "amber": "#FBBF24", "red": "#FB7185", "blue": "#60A5FA", "slate": "#94A3B8",
     "teal": "#2DD4BF", "orange": "#FB923C"}
GOOD, WARN, BAD, INFO = C["green"], C["amber"], C["red"], C["cyan"]

# Un color fijo por disco físico, igual en todos los paneles (sda=media2, sdc=media3, sdb=media4, sdd=sistema)
DISK_COLOR = {"sda": C["cyan"], "sdb": C["pink"], "sdc": C["violet"], "sdd": C["amber"]}
MOUNT_COLOR = {"/": C["amber"], "/mnt/media2": C["cyan"], "/mnt/media3": C["violet"],
               "/mnt/media4": C["pink"], "/mnt/unified-media": C["teal"]}

LINKS = [{"asDropdown": True, "icon": "dashboard", "includeVars": False, "keepTime": True,
          "tags": ["sparky"], "targetBlank": False, "title": "Dashboards Sparky",
          "tooltip": "", "type": "dashboards", "url": ""}]


def th(*p):
    out = [{"color": p[0][0], "value": None}]
    for c, v in p[1:]:
        out.append({"color": c, "value": v})
    return out


def fixed(c):
    return {"mode": "fixed", "fixedColor": c}


def prop(pid, value):
    return {"id": pid, "value": value}


def by_name(name, *props):
    return {"matcher": {"id": "byName", "options": name}, "properties": list(props)}


def by_regex(rx, *props):
    return {"matcher": {"id": "byRegexp", "options": rx}, "properties": list(props)}


def color_of(c):
    return prop("color", fixed(c))


def val_map(d):
    """{"0": ("CAÍDO", color), ...} -> mappings de Grafana"""
    return [{"type": "value", "options": {k: {"text": t, "color": c, "index": i}
                                          for i, (k, (t, c)) in enumerate(d.items())}}]


def variable_query(name, label, query, default=None):
    """default: lista de valores preseleccionados (ej. ["media"]); None = All."""
    cur = {"selected": True, "text": default or ["All"], "value": default or ["$__all"]}
    return {"name": name, "label": label, "type": "query", "hide": 0, "refresh": 2, "sort": 1,
            "query": {"query": query, "refId": "PrometheusVariableQueryEditor-VariableQuery"},
            "definition": query, "multi": True, "includeAll": True, "allValue": ".*",
            "current": cur, "options": [], "regex": "", "skipUrlSync": False}


class Board:
    def __init__(self, title, uid, tags, variables=None, desc="", time_from="now-3h"):
        self.n = 0
        self.x = self.y = self.rowh = 0
        self.d = {"title": title, "uid": uid, "description": desc, "schemaVersion": 39, "version": 1,
                  "editable": True, "graphTooltip": 1, "refresh": "30s", "timezone": "browser",
                  "time": {"from": time_from, "to": "now"},
                  "timepicker": {"refresh_intervals": ["10s", "30s", "1m", "5m"]},
                  "tags": tags, "templating": {"list": variables or []},
                  "annotations": {"list": []}, "links": LINKS, "panels": []}

    # ---------- layout ----------
    def section(self, title):
        self.y += self.rowh
        self.x = self.rowh = 0
        self.n += 1
        self.d["panels"].append({"id": self.n, "type": "row", "title": title, "collapsed": False,
                                 "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.y += 1

    def _place(self, w, h):
        if self.x + w > 24:
            self.y += self.rowh
            self.x = self.rowh = 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.rowh = max(self.rowh, h)
        return pos

    # ---------- panel base ----------
    def _panel(self, ptype, title, targets, w, h, unit=None, desc="", thr=None, mappings=None,
               minv=None, maxv=None, decimals=None, color=None, options=None, custom=None,
               overrides=None, transforms=None, transparent=False, no_value=None, instant=False,
               table=False, color_mode=None):
        self.n += 1
        ts = []
        for i, t in enumerate(targets):
            if isinstance(t, str):
                t = (t, None)
            tt = {"refId": chr(65 + i), "expr": t[0], "editorMode": "code"}
            if len(t) > 1 and t[1]:
                tt["legendFormat"] = t[1]
            if instant:
                tt["instant"] = True
                tt["range"] = False
            if table:
                tt["format"] = "table"
            ts.append(tt)
        dfl = {}
        if unit:
            dfl["unit"] = unit
        if minv is not None:
            dfl["min"] = minv
        if maxv is not None:
            dfl["max"] = maxv
        if decimals is not None:
            dfl["decimals"] = decimals
        if thr:
            dfl["thresholds"] = {"mode": "absolute", "steps": thr}
        if color:
            dfl["color"] = fixed(color)
        elif color_mode:
            dfl["color"] = {"mode": color_mode}
        elif thr:
            dfl["color"] = {"mode": "thresholds"}
        if mappings:
            dfl["mappings"] = mappings
        if custom:
            dfl["custom"] = custom
        if no_value:
            dfl["noValue"] = no_value
        p = {"id": self.n, "type": ptype, "title": title, "description": desc,
             "gridPos": self._place(w, h), "targets": ts,
             "fieldConfig": {"defaults": dfl, "overrides": overrides or []}}
        if options:
            p["options"] = options
        if transforms:
            p["transformations"] = transforms
        if transparent:
            p["transparent"] = True
        self.d["panels"].append(p)

    # ---------- tipos de panel ----------
    def stat(self, title, targets, w=3, h=4, spark=True, named=False, mode="value", **kw):
        if isinstance(targets, str):
            targets = [targets]
        opt = {"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
               "orientation": "auto", "textMode": "value_and_name" if named else "auto",
               "colorMode": mode, "graphMode": "area" if spark else "none",
               "justifyMode": "auto", "wideLayout": True, "showPercentChange": False}
        kw.setdefault("transparent", True)
        self._panel("stat", title, targets, w, h, options=opt, instant=not spark, **kw)

    def gauge(self, title, expr, w=4, h=6, unit="percent", minv=0, maxv=100, **kw):
        opt = {"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
               "orientation": "auto", "showThresholdLabels": False, "showThresholdMarkers": True,
               "minVizHeight": 75, "minVizWidth": 75, "sizing": "auto"}
        kw.setdefault("transparent", True)
        self._panel("gauge", title, [expr], w, h, unit=unit, minv=minv, maxv=maxv, options=opt,
                    instant=True, **kw)

    def ts(self, title, targets, w=12, h=8, stack=False, fill=22, legend="list", calcs=None,
           interp="smooth", thr_style=None, minv=0, bars=False, color=None, **kw):
        custom = {"drawStyle": "bars" if bars else "line", "lineInterpolation": interp,
                  "lineWidth": 1 if stack else 2, "fillOpacity": fill, "gradientMode": "opacity",
                  "showPoints": "never", "spanNulls": True, "axisBorderShow": False,
                  "axisPlacement": "auto", "barAlignment": 0,
                  "stacking": {"mode": "normal" if stack else "none", "group": "A"},
                  "thresholdsStyle": {"mode": thr_style or "off"}}
        if legend == "none":
            lg = {"showLegend": False, "displayMode": "list", "placement": "bottom", "calcs": []}
        elif legend == "table":
            lg = {"showLegend": True, "displayMode": "table", "placement": "right",
                  "calcs": calcs or ["lastNotNull", "max"]}
        else:
            lg = {"showLegend": True, "displayMode": "list", "placement": "bottom", "calcs": []}
        opt = {"legend": lg, "tooltip": {"mode": "multi", "sort": "desc"}}
        self._panel("timeseries", title, targets, w, h, options=opt, custom=custom, minv=minv,
                    color=color, color_mode=None if color else "palette-classic-by-name", **kw)

    def bar(self, title, targets, w=12, h=8, mode="lcd", **kw):
        opt = {"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
               "orientation": "horizontal", "displayMode": mode, "valueMode": "color",
               "namePlacement": "auto", "showUnfilled": True, "minVizHeight": 12,
               "minVizWidth": 8, "maxVizHeight": 300, "sizing": "auto"}
        kw.setdefault("transparent", True)
        self._panel("bargauge", title, targets, w, h, options=opt, instant=True, **kw)

    def donut(self, title, targets, w=6, h=8, **kw):
        opt = {"pieType": "donut", "displayLabels": ["percent"], "tooltip": {"mode": "single", "sort": "none"},
               "legend": {"showLegend": True, "displayMode": "table", "placement": "right",
                          "values": ["value", "percent"]},
               "reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""}}
        self._panel("piechart", title, targets, w, h, options=opt, instant=True,
                    color_mode="palette-classic-by-name", custom={"hideFrom": {"legend": False, "tooltip": False, "viz": False}}, **kw)

    def table(self, title, targets, w=12, h=8, sort=None, **kw):
        opt = {"showHeader": True, "cellHeight": "md", "footer": {"show": False, "reducer": ["sum"], "fields": ""}}
        if sort:
            opt["sortBy"] = [{"displayName": sort, "desc": True}]
        custom = {"align": "auto", "cellOptions": {"type": "auto"}, "inspect": False}
        self._panel("table", title, targets, w, h, options=opt, custom=custom, instant=True, table=True, **kw)

    def timeline(self, title, targets, w=12, h=8, **kw):
        opt = {"mergeValues": True, "showValue": "never", "alignValue": "center", "rowHeight": 0.85,
               "legend": {"showLegend": False, "displayMode": "list", "placement": "bottom"},
               "tooltip": {"mode": "single", "sort": "none"}}
        self._panel("state-timeline", title, targets, w, h, options=opt,
                    custom={"fillOpacity": 78, "lineWidth": 0, "spanNulls": False}, **kw)

    def heatmap(self, title, expr, w=12, h=8, unit="s", **kw):
        opt = {"calculate": False, "cellGap": 1, "filterValues": {"le": 1e-9},
               "color": {"mode": "scheme", "scheme": "Turbo", "fill": "dark-orange", "scale": "exponential",
                         "exponent": 0.5, "steps": 64, "reverse": False},
               "exemplars": {"color": "rgba(255,0,255,0.7)"}, "legend": {"show": True},
               "rowsFrame": {"layout": "auto"}, "tooltip": {"mode": "single", "yHistogram": False, "show": True},
               "yAxis": {"axisPlacement": "left", "reverse": False, "unit": unit}}
        self._panel("heatmap", title, [(expr, "{{le}}")], w, h, options=opt, **kw)
        self.d["panels"][-1]["targets"][0]["format"] = "heatmap"

    def text(self, md, w=24, h=3):
        self.n += 1
        self.d["panels"].append({"id": self.n, "type": "text", "title": "", "transparent": True,
                                 "gridPos": self._place(w, h),
                                 "options": {"mode": "markdown", "content": md}})

    def _colorize(self):
        """Color por identidad para series de discos y montajes (evita que todo quede verde por los umbrales)."""
        for p in self.d["panels"]:
            if p["type"] not in ("timeseries", "bargauge"):
                continue
            legs = {t.get("legendFormat") for t in p.get("targets", [])}
            if "{{mountpoint}}" in legs:
                src = MOUNT_COLOR
            elif "{{device}}" in legs and p["type"] == "timeseries":
                src = DISK_COLOR
            else:
                continue
            ov = p["fieldConfig"]["overrides"]
            have = {o["matcher"]["options"] for o in ov if o["matcher"]["id"] == "byName"}
            for k, c in src.items():
                if k not in have:
                    ov.append(by_name(k, color_of(c)))

    def save(self, path):
        self._colorize()
        with open(path, "w") as f:
            json.dump(self.d, f, separators=(",", ":"), ensure_ascii=False)
PYLIB2
cat > "$GEN/phase6b4.py" <<'PYGEN4'
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dashlib2 import (Board, C, GOOD, WARN, BAD, INFO, th, prop, by_name, by_regex, color_of,
                      val_map, variable_query)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dashboards-src")
RI = "$__rate_interval"
UP_DOWN = val_map({"0": ("CAÍDO", BAD), "1": ("OK", GOOD)})
CPU_USED = f'100 - avg(rate(node_cpu_seconds_total{{mode="idle"}}[{RI}])) * 100'
MEM_USED = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100"
PCT_HEALTH = th((BAD, None), (WARN, 90), (GOOD, 99.9))
CLASS_COLORS = [by_name("2xx", color_of(GOOD)), by_name("3xx", color_of(C["blue"])),
                by_name("4xx", color_of(WARN)), by_name("5xx", color_of(BAD))]
HTTP_CLASSES = [(f'sum(rate(traefik_service_requests_total{{code=~"{c}.."}}[{RI}])) or vector(0)', f"{c}xx")
                for c in "2345"]
DASH = {"fill": "dash", "dash": [10, 10]}

# =====================================================================
#  1) k3s · Cluster
# =====================================================================
NS = 'namespace=~"$namespace"'
CTR = f'{NS},container!="",container!="POD"'
CTR_ALL = 'container!="",container!="POD"'

b = Board("k3s · Cluster", "k3s-pods", ["sparky", "k3s"],
          variables=[variable_query("namespace", "Namespace", "label_values(kube_pod_info, namespace)")],
          desc="Estado, capacidad y consumo del cluster k3s. Filtrá por namespace arriba a la izquierda.")

b.section("Estado del cluster")
b.stat("Nodo", ['sum(kube_node_status_condition{condition="Ready",status="true"})'], spark=False,
       thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
b.stat("Pods sanos", [f'sum(kube_pod_status_phase{{{NS},phase="Running"}}) / sum(kube_pod_status_phase{{{NS},phase=~"Running|Pending|Failed|Unknown"}}) * 100'],
       unit="percent", decimals=1, thr=PCT_HEALTH, desc="Pods Running sobre el total de pods activos (sin contar Completed).")
b.stat("Pods Running", [f'sum(kube_pod_status_phase{{{NS},phase="Running"}})'], color=INFO)
b.stat("Pods con problemas", [f'sum(kube_pod_status_phase{{{NS},phase=~"Pending|Failed|Unknown"}}) or vector(0)'],
       thr=th((GOOD, None), (WARN, 1), (BAD, 3)))
b.stat("CrashLoopBackOff", [f'sum(kube_pod_container_status_waiting_reason{{{NS},reason="CrashLoopBackOff"}}) or vector(0)'],
       thr=th((GOOD, None), (BAD, 1)))
b.stat("Reinicios (1 h)", [f'sum(increase(kube_pod_container_status_restarts_total{{{NS}}}[1h])) or vector(0)'],
       thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
b.stat("Deployments disponibles", [f'sum(kube_deployment_status_replicas_available{{{NS}}}) / sum(kube_deployment_spec_replicas{{{NS}}}) * 100'],
       unit="percent", decimals=1, thr=PCT_HEALTH)
b.stat("API server: errores 5xx", [f'(sum(rate(apiserver_request_total{{code=~"5.."}}[{RI}])) or vector(0)) / sum(rate(apiserver_request_total[{RI}])) * 100'],
       unit="percent", decimals=2, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))

b.section("Capacidad del nodo")
b.gauge("CPU en uso", CPU_USED, thr=th((GOOD, None), (WARN, 70), (BAD, 90)))
b.gauge("CPU reservada (requests)", 'sum(kube_pod_container_resource_requests{resource="cpu"}) / sum(kube_node_status_allocatable{resource="cpu"}) * 100',
        thr=th((GOOD, None), (WARN, 70), (BAD, 90)),
        desc="Lo que los pods piden al scheduler sobre lo asignable del nodo. Cerca de 100% = no entran más pods.")
b.gauge("Memoria en uso", MEM_USED, thr=th((GOOD, None), (WARN, 80), (BAD, 90)))
b.gauge("Memoria reservada (requests)", 'sum(kube_pod_container_resource_requests{resource="memory"}) / sum(kube_node_status_allocatable{resource="memory"}) * 100',
        thr=th((GOOD, None), (WARN, 70), (BAD, 90)))
b.gauge("Pods / capacidad", 'max(kubelet_running_pods) / sum(kube_node_status_allocatable{resource="pods"}) * 100',
        thr=th((GOOD, None), (WARN, 70), (BAD, 90)), desc="Pods corriendo sobre el máximo que admite el nodo (110 por defecto en k3s).")
b.gauge("PVC más lleno", 'max(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100',
        thr=th((GOOD, None), (WARN, 75), (BAD, 90)))

b.section("Cargas de trabajo")
b.ts("Pods por fase", [(f'sum by (phase) (kube_pod_status_phase{{{NS}}})', "{{phase}}")], w=8, stack=True, fill=35,
     overrides=[by_name("Running", color_of(INFO)), by_name("Pending", color_of(WARN)),
                by_name("Failed", color_of(BAD)), by_name("Succeeded", color_of(C["slate"])),
                by_name("Unknown", color_of(C["pink"]))])
b.table("Namespaces",
        [(f'count by (namespace) (kube_pod_info{{{NS}}})', ""),
         (f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CTR}}}[{RI}]))', ""),
         (f'sum by (namespace) (container_memory_working_set_bytes{{{CTR}}})', ""),
         (f'sum by (namespace) (increase(kube_pod_container_status_restarts_total{{{NS}}}[1h]))', "")],
        w=16, sort="Memoria",
        transforms=[{"id": "joinByField", "options": {"byField": "namespace", "mode": "outer"}},
                    {"id": "filterFieldsByName", "options": {"include": {"names": ["namespace", "Value #A", "Value #B", "Value #C", "Value #D"]}}},
                    {"id": "organize", "options": {"renameByName": {"namespace": "Namespace", "Value #A": "Pods", "Value #B": "CPU (núcleos)",
                                                                    "Value #C": "Memoria", "Value #D": "Reinicios 1 h"},
                                                   "indexByName": {"namespace": 0, "Value #A": 1, "Value #B": 2, "Value #C": 3, "Value #D": 4}}}],
        overrides=[by_name("Memoria", prop("unit", "bytes"), prop("custom.cellOptions", {"type": "gauge", "mode": "gradient"}),
                           prop("color", {"mode": "fixed", "fixedColor": C["violet"]}), prop("min", 0)),
                   by_name("CPU (núcleos)", prop("decimals", 2), prop("custom.cellOptions", {"type": "gauge", "mode": "gradient"}),
                           prop("color", {"mode": "fixed", "fixedColor": INFO}), prop("min", 0)),
                   by_name("Reinicios 1 h", prop("decimals", 0), prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}),
                           prop("thresholds", {"mode": "absolute", "steps": th((GOOD, None), (WARN, 1), (BAD, 10))}),
                           prop("color", {"mode": "thresholds"})),
                   by_name("Pods", prop("decimals", 0))])

b.section("Consumo de recursos")
b.ts("CPU por namespace (núcleos)", [(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CTR}}}[{RI}]))', "{{namespace}}")],
     h=9, stack=True, fill=30, legend="table", unit="short", decimals=2)
b.ts("Memoria por namespace", [(f'sum by (namespace) (container_memory_working_set_bytes{{{CTR}}})', "{{namespace}}")],
     h=9, stack=True, fill=30, legend="table", unit="bytes")
b.ts("CPU: uso vs reservado vs capacidad (todo el cluster)",
     [(f'sum(rate(container_cpu_usage_seconds_total{{{CTR_ALL}}}[{RI}]))', "Uso"),
      ('sum(kube_pod_container_resource_requests{resource="cpu"})', "Reservado"),
      ('sum(kube_node_status_allocatable{resource="cpu"})', "Capacidad")],
     unit="short", decimals=2,
     overrides=[by_name("Uso", color_of(INFO), prop("custom.fillOpacity", 35)), by_name("Reservado", color_of(C["violet"])),
                by_name("Capacidad", color_of(BAD), prop("custom.lineStyle", DASH), prop("custom.fillOpacity", 0))])
b.ts("Memoria: uso vs reservado vs capacidad (todo el cluster)",
     [(f'sum(container_memory_working_set_bytes{{{CTR_ALL}}})', "Uso"),
      ('sum(kube_pod_container_resource_requests{resource="memory"})', "Reservado"),
      ('sum(kube_node_status_allocatable{resource="memory"})', "Capacidad")],
     unit="bytes",
     overrides=[by_name("Uso", color_of(INFO), prop("custom.fillOpacity", 35)), by_name("Reservado", color_of(C["violet"])),
                by_name("Capacidad", color_of(BAD), prop("custom.lineStyle", DASH), prop("custom.fillOpacity", 0))])
b.bar("Top 10 pods por CPU", [(f'sort_desc(topk(10, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{CTR}}}[{RI}]))))', "{{namespace}}/{{pod}}")],
      w=8, h=9, mode="lcd", unit="short", decimals=3, color=INFO, minv=0)
b.bar("Top 10 pods por memoria", [(f'sort_desc(topk(10, sum by (namespace, pod) (container_memory_working_set_bytes{{{CTR}}})))', "{{namespace}}/{{pod}}")],
      w=8, h=9, mode="gradient", unit="bytes", color=C["violet"], minv=0)
b.bar("CPU throttling (top 10)",
      [(f'sort_desc(topk(10, sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{{{CTR}}}[{RI}])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{{{CTR}}}[{RI}])) * 100))', "{{namespace}}/{{pod}}")],
      w=8, h=9, mode="gradient", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 10), (BAD, 30)),
      no_value="Sin throttling",
      desc="Porcentaje de períodos en que el contenedor fue frenado por su límite de CPU.")

b.section("Red, API server y DNS")
b.ts("Tráfico de pods (todo el cluster)",
     [(f'sum(rate(container_network_receive_bytes_total{{{NS}}}[{RI}]))', "Entrada ↓"),
      (f'sum(rate(container_network_transmit_bytes_total{{{NS}}}[{RI}]))', "Salida ↑")],
     unit="Bps", overrides=[by_name("Entrada ↓", color_of(INFO)),
                            by_name("Salida ↑", color_of(C["pink"]), prop("custom.transform", "negative-Y"))])
b.ts("API server: peticiones por código", [(f'sum by (code) (rate(apiserver_request_total[{RI}]))', "{{code}}")],
     stack=True, fill=30, unit="reqps",
     overrides=[by_regex("^2.*", color_of(GOOD)), by_regex("^3.*", color_of(C["blue"])),
                by_regex("^4.*", color_of(WARN)), by_regex("^5.*", color_of(BAD))])
b.ts("API server: latencia",
     [(f'histogram_quantile(0.50, sum by (le) (rate(apiserver_request_duration_seconds_bucket{{verb!~"WATCH|CONNECT"}}[{RI}])))', "p50"),
      (f'histogram_quantile(0.95, sum by (le) (rate(apiserver_request_duration_seconds_bucket{{verb!~"WATCH|CONNECT"}}[{RI}])))', "p95"),
      (f'histogram_quantile(0.99, sum by (le) (rate(apiserver_request_duration_seconds_bucket{{verb!~"WATCH|CONNECT"}}[{RI}])))', "p99")],
     unit="s", fill=12,
     overrides=[by_name("p50", color_of(GOOD)), by_name("p95", color_of(WARN)), by_name("p99", color_of(BAD))])
b.heatmap("API server: distribución de latencia",
          f'sum by (le) (increase(apiserver_request_duration_seconds_bucket{{verb!~"WATCH|CONNECT"}}[{RI}]))',
          desc="Cada celda es cuántas peticiones cayeron en ese rango de latencia. Más brillante = más peticiones.")
b.ts("CoreDNS: respuestas por tipo", [(f'sum by (rcode) (rate(coredns_dns_responses_total[{RI}]))', "{{rcode}}")],
     stack=True, fill=30, unit="reqps",
     overrides=[by_name("NOERROR", color_of(GOOD)), by_name("NXDOMAIN", color_of(WARN)), by_name("SERVFAIL", color_of(BAD))])
b.ts("CoreDNS: latencia p99",
     [(f'histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[{RI}])))', "p99")],
     unit="s", color=C["violet"])

b.section("Volúmenes (PVC)")
b.bar("Uso de cada volumen",
      [(f'sort_desc(kubelet_volume_stats_used_bytes{{{NS}}} / kubelet_volume_stats_capacity_bytes{{{NS}}} * 100)', "{{namespace}}/{{persistentvolumeclaim}}")],
      mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 75), (BAD, 90)), no_value="Sin datos de volúmenes")
b.bar("Espacio usado por volumen",
      [(f'sort_desc(kubelet_volume_stats_used_bytes{{{NS}}})', "{{namespace}}/{{persistentvolumeclaim}}")],
      mode="gradient", unit="bytes", color=C["violet"], minv=0, no_value="Sin datos de volúmenes")
b.save(os.path.join(OUT, "k3s-pods.json"))

# =====================================================================
#  2) Sparky · Centro de mando
# =====================================================================
h = Board("Sparky · Centro de mando", "sparky-home", ["sparky", "inicio"],
          desc="Vista única: salud general, recursos, tráfico, plataforma, discos y contenedores.")
h.text("# ⚡ SPARKY · centro de mando\nk3s · plataforma · servidor · discos &nbsp;—&nbsp; se actualiza cada 30 s", h=3)

h.section("Salud general")
h.stat("Targets de métricas", ["avg(up) * 100"], w=4, unit="percent", decimals=1, thr=PCT_HEALTH, desc="Porcentaje de exporters que responden.")
h.stat("Nodo k3s", ['sum(kube_node_status_condition{condition="Ready",status="true"})'], w=4, spark=False,
       thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
h.stat("Pods sanos", ['sum(kube_pod_status_phase{phase="Running"}) / sum(kube_pod_status_phase{phase=~"Running|Pending|Failed|Unknown"}) * 100'],
       w=4, unit="percent", decimals=1, thr=PCT_HEALTH)
h.stat("Apps ArgoCD sanas", ['sum(argocd_app_info{health_status="Healthy"}) / count(argocd_app_info) * 100'],
       w=4, unit="percent", decimals=0, thr=PCT_HEALTH)
h.stat("Certificados listos", ['sum(certmanager_certificate_ready_status{condition="True"}) / count(count by (name, namespace) (certmanager_certificate_ready_status)) * 100'],
       w=4, unit="percent", decimals=0, thr=PCT_HEALTH)
h.stat("Último backup", ['time() - max(velero_backup_last_successful_timestamp)'], w=4, unit="s", decimals=1,
       thr=th((GOOD, None), (WARN, 129600), (BAD, 172800)), desc="Tiempo desde el último backup exitoso de Velero. Verde: menos de 36 h.")
h.stat("Peticiones web", [f'sum(rate(traefik_service_requests_total[{RI}]))'], w=4, unit="reqps", decimals=2, color=INFO)
h.stat("Errores 5xx web", [f'(sum(rate(traefik_service_requests_total{{code=~"5.."}}[{RI}])) or vector(0)) / sum(rate(traefik_service_requests_total[{RI}])) * 100'],
       w=4, unit="percent", decimals=2, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
h.stat("Actualizaciones pendientes", ['sum(lab_pending_updates)'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 25)), desc="Paquetes pendientes en apt, snap y flatpak.")
h.stat("Reinicio requerido", ['max(lab_reboot_required)'], w=4, spark=False, thr=th((GOOD, None), (WARN, 1)),
       mappings=val_map({"0": ("No", GOOD), "1": ("Sí", WARN)}), mode="background")
h.stat("Discos SMART OK", ['sum(lab_smart_passed) / count(lab_smart_passed) * 100'], w=4, unit="percent", decimals=0, thr=th((BAD, None), (GOOD, 100)))
h.stat("Sectores pendientes", ['sum(lab_smart_attribute_raw{name="current_pending_sector"})'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 5)),
       desc="Suma de sectores pendientes de reasignar en todos los discos.")

h.section("Recursos del servidor")
h.gauge("CPU", CPU_USED, thr=th((GOOD, None), (WARN, 70), (BAD, 90)))
h.gauge("Memoria", MEM_USED, thr=th((GOOD, None), (WARN, 80), (BAD, 90)))
h.gauge("Disco del sistema", '100 - node_filesystem_avail_bytes{mountpoint="/",fstype="ext4"} / node_filesystem_size_bytes{mountpoint="/",fstype="ext4"} * 100',
        thr=th((GOOD, None), (WARN, 75), (BAD, 90)))
h.gauge("Presión de I/O (PSI)", f'rate(node_pressure_io_stalled_seconds_total[{RI}]) * 100', thr=th((GOOD, None), (WARN, 10), (BAD, 25)),
        maxv=50, desc="Porcentaje del tiempo con procesos detenidos esperando disco. Sostenido sobre 10% = discos saturados.")
h.gauge("Temperatura de discos (máx)", 'max(lab_smart_attribute_raw{name="temperature_celsius"})', unit="celsius", minv=20, maxv=70,
        thr=th((GOOD, None), (WARN, 50), (BAD, 60)))
h.gauge("Carga por núcleo", 'node_load1 / scalar(count(count by (cpu) (node_cpu_seconds_total))) * 100', thr=th((GOOD, None), (WARN, 80), (BAD, 120)),
        maxv=150, desc="Carga de 1 min dividida por núcleos. 100% = todos los núcleos ocupados.")

h.section("Actividad")
h.ts("CPU por namespace", [(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CTR_ALL}}}[{RI}]))', "{{namespace}}")],
     w=8, stack=True, fill=30, unit="short", decimals=2, legend="none")
h.ts("Tráfico web por clase HTTP", HTTP_CLASSES, w=8, stack=True, fill=40, unit="reqps", overrides=CLASS_COLORS)
h.ts("Red del servidor", [(f'sum(rate(node_network_receive_bytes_total{{device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*|wg.*"}}[{RI}]))', "Entrada ↓"),
                          (f'sum(rate(node_network_transmit_bytes_total{{device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*|wg.*"}}[{RI}]))', "Salida ↑")],
     w=8, unit="Bps", overrides=[by_name("Entrada ↓", color_of(INFO)), by_name("Salida ↑", color_of(C["pink"]), prop("custom.transform", "negative-Y"))])
h.donut("Memoria por namespace", [(f'sum by (namespace) (container_memory_working_set_bytes{{{CTR_ALL}}})', "{{namespace}}")], w=8, h=9, unit="bytes")
h.bar("Servicios web más usados", [(f'sort_desc(topk(8, sum by (service) (rate(traefik_service_requests_total[{RI}]))))', "{{service}}")],
      w=8, h=9, mode="gradient", unit="reqps", decimals=2, color=C["violet"], minv=0, no_value="Sin tráfico")
h.bar("Pods que más CPU usan", [(f'sort_desc(topk(8, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{CTR_ALL}}}[{RI}]))))', "{{namespace}}/{{pod}}")],
      w=8, h=9, mode="lcd", unit="short", decimals=3, color=INFO, minv=0)
h.section("Plataforma")
h.table("Aplicaciones ArgoCD", [("argocd_app_info", "")], w=12, h=9,
        transforms=[{"id": "filterFieldsByName", "options": {"include": {"names": ["name", "dest_namespace", "sync_status", "health_status"]}}},
                    {"id": "organize", "options": {"renameByName": {"name": "Aplicación", "dest_namespace": "Namespace", "sync_status": "Sync", "health_status": "Salud"},
                                                   "indexByName": {"name": 0, "dest_namespace": 1, "sync_status": 2, "health_status": 3}}}],
        overrides=[by_name("Salud", prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}), prop("custom.align", "center"),
                           prop("mappings", val_map({"Healthy": ("Healthy", GOOD), "Progressing": ("Progressing", C["blue"]), "Degraded": ("Degraded", BAD),
                                                     "Missing": ("Missing", WARN), "Suspended": ("Suspended", C["slate"]), "Unknown": ("Unknown", C["slate"])}))),
                   by_name("Sync", prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}), prop("custom.align", "center"),
                           prop("mappings", val_map({"Synced": ("Synced", GOOD), "OutOfSync": ("OutOfSync", WARN), "Unknown": ("Unknown", C["slate"])})))])
h.bar("Certificados: días para vencer",
      [('sort((certmanager_certificate_expiration_timestamp_seconds - time()) / 86400)', "{{namespace}}/{{name}}")],
      w=6, h=9, mode="lcd", unit="d", decimals=0, minv=0, maxv=90, thr=th((BAD, None), (WARN, 14), (GOOD, 30)))
h.bar("MinIO: uso por bucket", [('sort_desc(max by (bucket) (minio_bucket_usage_total_bytes))', "{{bucket}}")],
      w=6, h=9, mode="gradient", unit="bytes", color=C["violet"], minv=0, no_value="Sin buckets")
h.timeline("Disponibilidad de targets (últimas horas)", [("min by (job) (up)", "{{job}}")], w=12, h=8,
           mappings=val_map({"0": ("CAÍDO", BAD), "1": ("OK", GOOD)}))
h.stat("Backups de Velero", [('sum(velero_backup_success_total) or vector(0)', "Exitosos"), ('sum(velero_backup_failure_total) or vector(0)', "Con fallos")],
       w=6, h=8, spark=False, named=True,
       overrides=[by_name("Exitosos", color_of(INFO)), by_name("Con fallos", prop("thresholds", {"mode": "absolute", "steps": th((GOOD, None), (BAD, 1))}),
                                                                prop("color", {"mode": "thresholds"}))])
h.gauge("MinIO: capacidad usada", 'max((1 - minio_cluster_capacity_usable_free_bytes / minio_cluster_capacity_usable_total_bytes) * 100)',
        w=6, h=8, thr=th((GOOD, None), (WARN, 75), (BAD, 90)))

h.section("Discos del servidor")
h.bar("Uso de cada filesystem",
      [('100 - node_filesystem_avail_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"} / node_filesystem_size_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"} * 100', "{{mountpoint}}")],
      w=8, h=9, mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 75), (BAD, 90)))
h.ts("Utilización de cada disco", [(f'rate(node_disk_io_time_seconds_total{{device=~"sd[a-d]"}}[{RI}]) * 100', "{{device}}")],
     w=8, h=9, unit="percent", maxv=100, thr=th((GOOD, None), (BAD, 90)), thr_style="dashed")
h.ts("Temperatura de discos", [('lab_smart_attribute_raw{name="temperature_celsius"}', "{{device}}")], w=8, h=9, unit="celsius", minv=20,
     thr=th((GOOD, None), (WARN, 50), (BAD, 60)), thr_style="dashed")
h.ts("Presión PSI", [(f'rate(node_pressure_io_stalled_seconds_total[{RI}]) * 100', "I/O detenido"),
                     (f'rate(node_pressure_cpu_waiting_seconds_total[{RI}]) * 100', "CPU esperando"),
                     (f'rate(node_pressure_memory_stalled_seconds_total[{RI}]) * 100', "Memoria detenida")],
     unit="percent", overrides=[by_name("I/O detenido", color_of(BAD)), by_name("CPU esperando", color_of(INFO)), by_name("Memoria detenida", color_of(C["violet"]))])
h.ts("Lectura / escritura de discos",
     [(f'sum(rate(node_disk_read_bytes_total{{device=~"sd[a-d]"}}[{RI}]))', "Lectura ↓"),
      (f'sum(rate(node_disk_written_bytes_total{{device=~"sd[a-d]"}}[{RI}]))', "Escritura ↑")],
     unit="Bps", overrides=[by_name("Lectura ↓", color_of(INFO)), by_name("Escritura ↑", color_of(C["pink"]), prop("custom.transform", "negative-Y"))])

h.section("Docker y LocalStack")
h.stat("Docker", ["lab_docker_up"], w=4, h=5, spark=False, thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
h.stat("LocalStack", ["lab_localstack_up"], w=4, h=5, spark=False, thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
h.stat("Servicios de LocalStack activos", ["sum(lab_localstack_service_running)"], w=4, h=5, color=INFO, spark=False)
h.stat("Contenedores corriendo", ["sum(lab_docker_container_running)"], w=4, h=5, color=INFO, spark=False)
h.ts("CPU de contenedores Docker", [("lab_docker_container_cpu_percent", "{{name}}")], w=8, h=5, unit="percent")
h.save(os.path.join(OUT, "sparky-home.json"))
print("ok")
PYGEN4
cat > "$GEN/phase6b5.py" <<'PYGEN5'
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dashlib2 import (Board, C, GOOD, WARN, BAD, INFO, th, prop, by_name, by_regex, color_of,
                      val_map, variable_query)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dashboards-src")
RI = "$__rate_interval"
VIOLET, PINK, BLUE, SLATE = C["violet"], C["pink"], C["blue"], C["slate"]
UP_DOWN = val_map({"0": ("CAÍDO", BAD), "1": ("OK", GOOD)})
PCT_HEALTH = th((BAD, None), (WARN, 90), (GOOD, 99.9))
CPU_USED = f'100 - avg(rate(node_cpu_seconds_total{{mode="idle"}}[{RI}])) * 100'
MEM_USED = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100"
NETF = 'device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*|wg.*"'
DISK = 'device=~"sd[a-d]"'
CODE_COLORS = [by_regex("^2.*", color_of(GOOD)), by_regex("^3.*", color_of(BLUE)),
               by_regex("^4.*", color_of(WARN)), by_regex("^5.*", color_of(BAD))]
CLASS_COLORS = [by_name("2xx", color_of(GOOD)), by_name("3xx", color_of(BLUE)),
                by_name("4xx", color_of(WARN)), by_name("5xx", color_of(BAD))]
HTTP_CLASSES = [(f'sum(rate(traefik_service_requests_total{{code=~"{c}.."}}[{RI}])) or vector(0)', f"{c}xx") for c in "2345"]
NEG = lambda name, c: by_name(name, color_of(c), prop("custom.transform", "negative-Y"))
SMART = 'lab_smart_attribute_raw'

# =====================================================================
#  1) Servidor y discos  (reemplaza a servidor-discos y servidor-recursos)
# =====================================================================
s = Board("Servidor y discos", "servidor-discos", ["sparky", "host"],
          desc="CPU, memoria, red, discos, salud SMART y mantenimiento del host.")
s.section("Estado general")
s.stat("CPU usada", [CPU_USED], w=4, unit="percent", decimals=0, thr=th((GOOD, None), (WARN, 70), (BAD, 90)))
s.stat("Memoria usada", [MEM_USED], w=4, unit="percent", decimals=0, thr=th((GOOD, None), (WARN, 80), (BAD, 90)))
s.stat("Swap usada", ["node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes"], w=4, unit="bytes",
       thr=th((GOOD, None), (WARN, 512 * 1024**2), (BAD, 2 * 1024**3)))
s.stat("Carga (1 min)", ["node_load1"], w=4, decimals=2, thr=th((GOOD, None), (WARN, 4), (BAD, 8)), desc="El equipo tiene 4 núcleos: cerca de 4 = al límite.")
s.stat("Tiempo encendido", ["time() - node_boot_time_seconds"], w=4, unit="s", decimals=0, color=INFO, spark=False)
s.stat("Presión de I/O (PSI)", [f"rate(node_pressure_io_stalled_seconds_total[{RI}]) * 100"], w=4, unit="percent", decimals=1,
       thr=th((GOOD, None), (WARN, 10), (BAD, 25)), desc="Tiempo con procesos detenidos esperando disco.")
s.stat("Discos SMART OK", ["sum(lab_smart_passed) / count(lab_smart_passed) * 100"], w=4, unit="percent", decimals=0, thr=th((BAD, None), (GOOD, 100)))
s.stat("Sectores pendientes", [f'sum({SMART}{{name="current_pending_sector"}})'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
s.stat("Sectores reubicados", [f'sum({SMART}{{name="reallocated_sector_ct"}})'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
s.stat("CRC nuevos (24 h)", [f'sum(delta({SMART}{{name="udma_crc_error_count"}}[24h]))'], w=4, thr=th((GOOD, None), (BAD, 1)),
       desc="Errores de cable/puerto SATA aparecidos en las últimas 24 h. 0 = el contador histórico no está creciendo.")
s.stat("Temperatura máx. discos", [f'max({SMART}{{name="temperature_celsius"}})'], w=4, unit="celsius", thr=th((GOOD, None), (WARN, 50), (BAD, 60)))
s.stat("Horas de uso (máx)", [f'max({SMART}{{name="power_on_hours"}})'], w=4, unit="h", decimals=0, color=SLATE, spark=False)

s.section("CPU, memoria y red")
s.ts("CPU por modo (% del total)",
     [(f'sum by (mode) (rate(node_cpu_seconds_total{{mode!="idle"}}[{RI}])) / scalar(count(count by (cpu) (node_cpu_seconds_total))) * 100', "{{mode}}")],
     w=8, unit="percent", maxv=100, stack=True, fill=35)
s.ts("Memoria", [("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "Usada"),
                 ("node_memory_Cached_bytes + node_memory_Buffers_bytes", "Caché y buffers"),
                 ("node_memory_MemTotal_bytes", "Total")], w=8, unit="bytes",
     overrides=[by_name("Usada", color_of(INFO), prop("custom.fillOpacity", 35)), by_name("Caché y buffers", color_of(VIOLET)),
                by_name("Total", color_of(BAD), prop("custom.lineStyle", {"fill": "dash", "dash": [10, 10]}), prop("custom.fillOpacity", 0))])
s.ts("Red del servidor", [(f"sum(rate(node_network_receive_bytes_total{{{NETF}}}[{RI}]))", "Entrada ↓"),
                         (f"sum(rate(node_network_transmit_bytes_total{{{NETF}}}[{RI}]))", "Salida ↑")],
     w=8, unit="Bps", overrides=[by_name("Entrada ↓", color_of(INFO)), NEG("Salida ↑", PINK)])

s.section("Discos")
s.bar("Uso de cada filesystem",
      [('100 - node_filesystem_avail_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"} / node_filesystem_size_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"} * 100', "{{mountpoint}}")],
      w=8, h=9, mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 75), (BAD, 90)))
s.ts("Utilización de cada disco", [(f'rate(node_disk_io_time_seconds_total{{{DISK}}}[{RI}]) * 100', "{{device}}")],
     w=8, h=9, unit="percent", maxv=100, thr=th((GOOD, None), (BAD, 90)), thr_style="dashed")
s.ts("Temperatura de discos", [(f'{SMART}{{name="temperature_celsius"}}', "{{device}}")], w=8, h=9, unit="celsius", minv=20,
     thr=th((GOOD, None), (WARN, 50), (BAD, 60)), thr_style="dashed")
s.ts("Lectura por disco", [(f'rate(node_disk_read_bytes_total{{{DISK}}}[{RI}])', "{{device}}")], w=8, unit="Bps")
s.ts("Escritura por disco", [(f'rate(node_disk_written_bytes_total{{{DISK}}}[{RI}])', "{{device}}")], w=8, unit="Bps")
s.ts("Presión PSI", [(f'rate(node_pressure_io_stalled_seconds_total[{RI}]) * 100', "I/O detenido"),
                     (f'rate(node_pressure_cpu_waiting_seconds_total[{RI}]) * 100', "CPU esperando"),
                     (f'rate(node_pressure_memory_stalled_seconds_total[{RI}]) * 100', "Memoria detenida")],
     w=8, unit="percent", overrides=[by_name("I/O detenido", color_of(BAD)), by_name("CPU esperando", color_of(INFO)), by_name("Memoria detenida", color_of(VIOLET))])

s.section("Salud SMART por disco")
s.bar("Sectores pendientes", [(f'{SMART}{{name="current_pending_sector"}}', "{{device}}")], w=6, h=7, mode="lcd", decimals=0, minv=0, maxv=10,
      thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
s.bar("Sectores reubicados", [(f'{SMART}{{name="reallocated_sector_ct"}}', "{{device}}")], w=6, h=7, mode="lcd", decimals=0, minv=0, maxv=10,
      thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
s.bar("Errores CRC acumulados", [(f'{SMART}{{name="udma_crc_error_count"}}', "{{device}}")], w=6, h=7, mode="gradient", decimals=0, minv=0,
      thr=th((GOOD, None), (WARN, 1), (BAD, 5000)), desc="Contador de por vida: sdb y sdd tienen historial. Lo que importa es que no crezca (ver 'CRC nuevos').")
s.bar("Horas de uso", [(f'{SMART}{{name="power_on_hours"}}', "{{device}}")], w=6, h=7, mode="gradient", unit="h", decimals=0, color=VIOLET, minv=0)

s.section("Mantenimiento del host")
s.stat("Actualizaciones pendientes", ["sum(lab_pending_updates)"], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 25)), desc="apt, snap y flatpak.")
s.stat("De seguridad pendientes", ["sum(lab_pending_security_updates)"], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
s.stat("Reinicio requerido", ["max(lab_reboot_required)"], w=4, spark=False, thr=th((GOOD, None), (WARN, 1)),
       mappings=val_map({"0": ("No", GOOD), "1": ("Sí", WARN)}), mode="background")
s.stat("Units systemd fallidas", ["sum(lab_systemd_failed_units)"], w=4, thr=th((GOOD, None), (BAD, 1)))
s.stat("Última actualización (updn)", ["time() - max(lab_updn_last_success_timestamp_seconds)"], w=4, unit="s", decimals=1,
       thr=th((GOOD, None), (WARN, 172800), (BAD, 604800)), desc="Tiempo desde la última corrida exitosa de updn.")
s.stat("Edad de las métricas del host", ["time() - max(lab_host_metrics_timestamp_seconds)"], w=4, unit="s", decimals=0,
       thr=th((GOOD, None), (WARN, 600), (BAD, 1800)), desc="Si pasa de 10 min, el timer lab-host-metrics dejó de correr.")
s.save(os.path.join(OUT, "servidor-discos.json"))

# =====================================================================
#  2) Docker y LocalStack
# =====================================================================
d = Board("Docker y LocalStack", "docker-localstack", ["sparky", "docker"],
          desc="Contenedores Docker del host y servicios de LocalStack.")
d.section("Estado")
d.stat("Docker", ["lab_docker_up"], w=4, spark=False, thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
d.stat("LocalStack", ["lab_localstack_up"], w=4, spark=False, thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
d.stat("Servicios activos", ["sum(lab_localstack_service_running)"], w=4, color=INFO, spark=False)
d.stat("Servicios reportados", ["count(lab_localstack_service_running)"], w=4, color=SLATE, spark=False)
d.stat("Contenedores corriendo", ["sum(lab_docker_container_running)"], w=4, color=INFO, spark=False)
d.stat("Edad de las métricas", ["time() - max(lab_host_metrics_timestamp_seconds)"], w=4, unit="s", decimals=0, thr=th((GOOD, None), (WARN, 600), (BAD, 1800)))
d.section("Consumo de los contenedores")
d.ts("CPU por contenedor", [("lab_docker_container_cpu_percent", "{{name}}")], unit="percent", legend="table")
d.ts("Memoria por contenedor", [("lab_docker_container_memory_bytes", "{{name}}")], unit="bytes", legend="table")
d.section("Servicios de LocalStack")
d.timeline("Disponibilidad por servicio", [("lab_localstack_service_running", "{{service}}")], w=24, h=14,
           mappings=val_map({"0": ("no", BAD), "1": ("sí", GOOD)}))
d.save(os.path.join(OUT, "docker-localstack.json"))

# =====================================================================
#  3) Plataforma: Traefik, ArgoCD, cert-manager, Velero, MinIO
# =====================================================================
p = Board("Plataforma", "plataforma", ["sparky", "plataforma"],
          desc="Traefik, ArgoCD, cert-manager, Velero y MinIO.")
p.section("Traefik")
p.stat("Peticiones por segundo", [f"sum(rate(traefik_service_requests_total[{RI}]))"], w=4, unit="reqps", decimals=2, color=INFO)
p.stat("Errores 5xx", [f'(sum(rate(traefik_service_requests_total{{code=~"5.."}}[{RI}])) or vector(0)) / sum(rate(traefik_service_requests_total[{RI}])) * 100'],
       w=4, unit="percent", decimals=2, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
p.stat("Tráfico cifrado (TLS)", [f"sum(rate(traefik_entrypoint_requests_tls_total[{RI}])) / sum(rate(traefik_entrypoint_requests_total[{RI}])) * 100"],
       w=4, unit="percent", decimals=0, color=VIOLET)
p.stat("Conexiones abiertas", ["sum(traefik_open_connections)"], w=4, color=INFO)
p.stat("Salida de datos", [f"sum(rate(traefik_entrypoint_responses_bytes_total[{RI}]))"], w=4, unit="Bps", color=PINK)
p.stat("Última recarga de config", ["min(traefik_config_last_reload_success)"], w=4, spark=False, thr=th((BAD, None), (GOOD, 1)),
       mappings=val_map({"0": ("FALLÓ", BAD), "1": ("OK", GOOD)}), mode="background")
p.ts("Peticiones por clase HTTP", HTTP_CLASSES, w=8, stack=True, fill=40, unit="reqps", overrides=CLASS_COLORS)
p.ts("Latencia de los servicios",
     [(f"histogram_quantile(0.50, sum by (le) (rate(traefik_service_request_duration_seconds_bucket[{RI}])))", "p50"),
      (f"histogram_quantile(0.95, sum by (le) (rate(traefik_service_request_duration_seconds_bucket[{RI}])))", "p95"),
      (f"histogram_quantile(0.99, sum by (le) (rate(traefik_service_request_duration_seconds_bucket[{RI}])))", "p99")],
     w=8, unit="s", fill=12, overrides=[by_name("p50", color_of(GOOD)), by_name("p95", color_of(WARN)), by_name("p99", color_of(BAD))])
p.ts("Peticiones por entrypoint", [(f"sum by (entrypoint) (rate(traefik_entrypoint_requests_total[{RI}]))", "{{entrypoint}}")], w=8, stack=True, fill=35, unit="reqps")
p.bar("Servicios más usados", [(f"sort_desc(topk(10, sum by (service) (rate(traefik_service_requests_total[{RI}]))))", "{{service}}")],
      w=12, h=9, mode="gradient", unit="reqps", decimals=3, color=VIOLET, minv=0, no_value="Sin tráfico")
p.bar("Servicios con errores 4xx/5xx", [(f'sort_desc(topk(10, sum by (service) (rate(traefik_service_requests_total{{code=~"4..|5.."}}[{RI}]))))', "{{service}}")],
      w=12, h=9, mode="gradient", unit="reqps", decimals=3, thr=th((GOOD, None), (WARN, 0.01), (BAD, 0.5)), minv=0, no_value="Sin errores")

p.section("ArgoCD")
p.stat("Apps sanas", ['sum(argocd_app_info{health_status="Healthy"}) / count(argocd_app_info) * 100'], w=8, unit="percent", decimals=0, thr=PCT_HEALTH)
p.stat("Apps fuera de sync", ['count(argocd_app_info{sync_status!="Synced"}) or vector(0)'], w=8, thr=th((GOOD, None), (WARN, 1)))
p.stat("Conexión al cluster", ["min(argocd_cluster_connection_status)"], w=8, spark=False, thr=th((BAD, None), (GOOD, 1)),
       mappings=val_map({"0": ("CAÍDA", BAD), "1": ("OK", GOOD)}), mode="background")
p.table("Aplicaciones", [("argocd_app_info", "")], w=12, h=7,
        transforms=[{"id": "filterFieldsByName", "options": {"include": {"names": ["name", "dest_namespace", "sync_status", "health_status"]}}},
                    {"id": "organize", "options": {"renameByName": {"name": "Aplicación", "dest_namespace": "Namespace", "sync_status": "Sync", "health_status": "Salud"},
                                                   "indexByName": {"name": 0, "dest_namespace": 1, "sync_status": 2, "health_status": 3}}}],
        overrides=[by_name("Salud", prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}), prop("custom.align", "center"),
                           prop("mappings", val_map({"Healthy": ("Healthy", GOOD), "Progressing": ("Progressing", BLUE), "Degraded": ("Degraded", BAD),
                                                     "Missing": ("Missing", WARN), "Suspended": ("Suspended", SLATE), "Unknown": ("Unknown", SLATE)}))),
                   by_name("Sync", prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}), prop("custom.align", "center"),
                           prop("mappings", val_map({"Synced": ("Synced", GOOD), "OutOfSync": ("OutOfSync", WARN), "Unknown": ("Unknown", SLATE)})))])
p.ts("Sincronizaciones por resultado", [(f"sum by (phase) (increase(argocd_app_sync_total[{RI}]))", "{{phase}}")], w=12, h=7, bars=True, stack=True, fill=70,
     overrides=[by_name("Succeeded", color_of(GOOD)), by_name("Failed", color_of(BAD)), by_name("Error", color_of(BAD)), by_name("Running", color_of(BLUE))])

p.section("cert-manager")
p.stat("Certificados listos", ['sum(certmanager_certificate_ready_status{condition="True"}) / count(count by (name, namespace) (certmanager_certificate_ready_status)) * 100'],
       w=8, unit="percent", decimals=0, thr=PCT_HEALTH)
p.stat("ClusterIssuers listos", ['min(certmanager_clusterissuer_ready_status{condition="True"})'], w=8, spark=False, thr=th((BAD, None), (GOOD, 1)),
       mappings=val_map({"0": ("NO", BAD), "1": ("OK", GOOD)}), mode="background")
p.stat("Errores de sync (1 h)", ["sum(increase(certmanager_controller_sync_error_count_total[1h])) or vector(0)"], w=8, thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
p.bar("Días para vencer", [("sort((certmanager_certificate_expiration_timestamp_seconds - time()) / 86400)", "{{namespace}}/{{name}}")],
      w=12, h=7, mode="lcd", unit="d", decimals=0, minv=0, maxv=90, thr=th((BAD, None), (WARN, 14), (GOOD, 30)))
p.ts("Peticiones ACME (Let's Encrypt)", [(f"sum by (status) (rate(certmanager_http_acme_client_request_count_total[{RI}]))", "{{status}}")], w=12, h=7, stack=True, fill=35,
     overrides=CODE_COLORS)

p.section("Velero (backups)")
p.stat("Último backup", ["time() - max(velero_backup_last_successful_timestamp)"], w=4, unit="s", decimals=1, thr=th((GOOD, None), (WARN, 129600), (BAD, 172800)),
       desc="Verde: menos de 36 h.")
p.stat("Exitosos", ["sum(velero_backup_success_total) or vector(0)"], w=4, color=INFO)
p.stat("Con fallos", ["sum(velero_backup_failure_total) or vector(0)"], w=4, thr=th((GOOD, None), (BAD, 1)))
p.stat("Parciales", ["sum(velero_backup_partial_failure_total) or vector(0)"], w=4, thr=th((GOOD, None), (WARN, 1)))
p.stat("Tamaño del último", ["max(velero_backup_tarball_size_bytes)"], w=4, unit="bytes", color=VIOLET)
p.stat("Ubicación de backup", ["min(velero_backup_location_status_gauge)"], w=4, spark=False, thr=th((BAD, None), (GOOD, 1)),
       mappings=val_map({"0": ("NO DISPONIBLE", BAD), "1": ("Disponible", GOOD)}), mode="background")
p.bar("Edad del último backup exitoso", [("sort_desc(time() - velero_backup_last_successful_timestamp)", "{{schedule}}")], w=8, h=7, mode="lcd", unit="s",
      decimals=1, minv=0, maxv=172800, thr=th((GOOD, None), (WARN, 129600), (BAD, 172800)))
p.ts("Tamaño de cada backup", [("velero_backup_tarball_size_bytes", "{{schedule}}")], w=8, h=7, unit="bytes")
p.ts("Objetos respaldados", [("velero_backup_items_total", "{{schedule}}")], w=8, h=7)

p.section("MinIO")
p.gauge("Capacidad usada", "max((1 - minio_cluster_capacity_usable_free_bytes / minio_cluster_capacity_usable_total_bytes) * 100)", w=6, thr=th((GOOD, None), (WARN, 75), (BAD, 90)))
p.stat("Objetos totales", ["sum(minio_bucket_usage_object_total)"], w=6, h=6, color=INFO)
p.stat("Discos online", ["min(minio_cluster_disk_online_total)"], w=6, h=6, color=GOOD, spark=False)
p.stat("Discos offline", ["max(minio_cluster_disk_offline_total) or vector(0)"], w=6, h=6, thr=th((GOOD, None), (BAD, 1)), spark=False)
p.bar("Uso por bucket", [("sort_desc(max by (bucket) (minio_bucket_usage_total_bytes))", "{{bucket}}")], w=8, h=7, mode="gradient", unit="bytes", color=VIOLET, minv=0)
p.ts("Tráfico por bucket (entrada)", [(f"sum by (bucket) (rate(minio_bucket_traffic_received_bytes[{RI}]))", "{{bucket}}")], w=8, h=7, unit="Bps")
p.ts("Descriptores de archivo y goroutines", [("max(minio_node_file_descriptor_open_total)", "Descriptores abiertos"), ("max(minio_node_go_routine_total)", "Goroutines")], w=8, h=7)
p.save(os.path.join(OUT, "plataforma.json"))

# =====================================================================
#  4) Apps y media
# =====================================================================
NSA = 'namespace=~"$namespace"'
PODF = f'{NSA},pod=~"$pod"'
CT = f'{PODF},container!="",container!="POD"'
SVC_NOISE = 'service!~"api@internal|noop@internal|.*acme.*"'
a = Board("Apps y media", "apps-media", ["sparky", "apps"],
          variables=[variable_query("namespace", "Namespace", "label_values(kube_pod_info, namespace)", default=["media"]),
                     variable_query("pod", "Pod", 'label_values(kube_pod_info{namespace=~"$namespace"}, pod)')],
          desc="Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent y demás apps. Elegí namespace y pods arriba.")
a.section("Estado de las apps")
a.stat("Pods listos", [f'sum(kube_pod_status_ready{{{NSA},condition="true"}}) / count(kube_pod_info{{{NSA}}}) * 100'], w=4, unit="percent", decimals=0, thr=PCT_HEALTH)
a.stat("Reinicios (24 h)", [f'sum(increase(kube_pod_container_status_restarts_total{{{PODF}}}[24h])) or vector(0)'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
a.stat("CPU", [f'sum(rate(container_cpu_usage_seconds_total{{{CT}}}[{RI}]))'], w=4, unit="short", decimals=2, color=INFO)
a.stat("Memoria", [f'sum(container_memory_working_set_bytes{{{CT}}})'], w=4, unit="bytes", color=VIOLET)
a.stat("Red entrada", [f'sum(rate(container_network_receive_bytes_total{{{PODF}}}[{RI}]))'], w=4, unit="Bps", color=INFO)
a.stat("Red salida", [f'sum(rate(container_network_transmit_bytes_total{{{PODF}}}[{RI}]))'], w=4, unit="Bps", color=PINK)
a.section("Consumo por pod")
a.ts("CPU por pod (núcleos)", [(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{CT}}}[{RI}]))', "{{pod}}")], h=9, stack=True, fill=30, unit="short", decimals=3, legend="table")
a.ts("Memoria por pod", [(f'sum by (pod) (container_memory_working_set_bytes{{{CT}}})', "{{pod}}")], h=9, stack=True, fill=30, unit="bytes", legend="table")
a.ts("Recibido por pod", [(f'sum by (pod) (rate(container_network_receive_bytes_total{{{PODF}}}[{RI}]))', "{{pod}}")], unit="Bps", stack=True, fill=30)
a.ts("Enviado por pod", [(f'sum by (pod) (rate(container_network_transmit_bytes_total{{{PODF}}}[{RI}]))', "{{pod}}")], unit="Bps", stack=True, fill=30)
a.bar("Reinicios por pod (24 h)", [(f'sort_desc(sum by (pod) (increase(kube_pod_container_status_restarts_total{{{PODF}}}[24h])) > 0)', "{{pod}}")],
      w=12, h=6, mode="lcd", decimals=0, minv=0, thr=th((GOOD, None), (WARN, 1), (BAD, 10)), no_value="Sin reinicios")
a.bar("CPU throttling por pod", [(f'sort_desc(sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{{{CT}}}[{RI}])) / sum by (pod) (rate(container_cpu_cfs_periods_total{{{CT}}}[{RI}])) * 100)', "{{pod}}")],
      w=12, h=6, mode="gradient", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 10), (BAD, 30)), no_value="Sin throttling")
a.section("Tráfico web (Traefik)")
a.ts("Peticiones por servicio", [(f'sum by (service) (rate(traefik_service_requests_total{{{SVC_NOISE}}}[{RI}]))', "{{service}}")], h=9, stack=True, fill=30, unit="reqps", legend="table")
a.ts("Errores 4xx/5xx por servicio", [(f'sum by (service) (rate(traefik_service_requests_total{{{SVC_NOISE},code=~"4..|5.."}}[{RI}])) > 0', "{{service}}")], h=9, unit="reqps",
     legend="table", no_value="Sin errores")
a.bar("Ancho de banda de salida por servicio", [(f'sort_desc(topk(8, sum by (service) (rate(traefik_service_responses_bytes_total{{{SVC_NOISE}}}[{RI}]))))', "{{service}}")],
      w=12, h=7, mode="gradient", unit="Bps", color=PINK, minv=0, no_value="Sin tráfico")
a.ts("Latencia p95 por servicio", [(f'histogram_quantile(0.95, sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket{{{SVC_NOISE}}}[{RI}])))', "{{service}}")],
     w=12, h=7, unit="s")
a.section("Almacenamiento de media")
a.bar("Uso de los discos de media", [('100 - node_filesystem_avail_bytes{mountpoint=~"/mnt/(media[0-9]|unified-media)"} / node_filesystem_size_bytes{mountpoint=~"/mnt/(media[0-9]|unified-media)"} * 100', "{{mountpoint}}")],
      w=8, h=8, mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 80), (BAD, 92)))
a.bar("Espacio libre", [('node_filesystem_avail_bytes{mountpoint=~"/mnt/(media[0-9]|unified-media)"}', "{{mountpoint}}")],
      w=8, h=8, mode="gradient", unit="bytes", color=C["teal"], minv=0)
a.ts("Utilización de los discos de media", [(f'rate(node_disk_io_time_seconds_total{{device=~"sd[a-c]"}}[{RI}]) * 100', "{{device}}")], w=8, h=8, unit="percent", maxv=100)
a.save(os.path.join(OUT, "apps-media.json"))

# =====================================================================
#  5) Guacamole
# =====================================================================
NSG = 'namespace="guacamole"'
GSVC = 'service=~".*guacamole.*"'
g = Board("Guacamole", "guacamole", ["sparky", "guacamole"],
          desc="Acceso remoto: salud de los pods, certificado, tráfico, intentos bloqueados y backups de la base.")
g.section("Estado")
g.stat("Deployments disponibles", [f'sum(kube_deployment_status_replicas_available{{{NSG}}}) / sum(kube_deployment_spec_replicas{{{NSG}}}) * 100'],
       w=4, unit="percent", decimals=0, thr=PCT_HEALTH, desc="guacamole, guacd y postgres.")
g.stat("Reinicios (24 h)", [f'sum(increase(kube_pod_container_status_restarts_total{{{NSG}}}[24h])) or vector(0)'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
g.stat("Certificado vence en", [f'min((certmanager_certificate_expiration_timestamp_seconds{{{NSG}}} - time()) / 86400)'], w=4, unit="d", decimals=0,
       thr=th((BAD, None), (WARN, 14), (GOOD, 30)))
g.stat("Peticiones web", [f'sum(rate(traefik_service_requests_total{{{GSVC}}}[{RI}]))'], w=4, unit="reqps", decimals=3, color=INFO)
g.stat("Respuestas 403 (1 h)", [f'sum(increase(traefik_service_requests_total{{{GSVC},code="403"}}[1h])) or vector(0)'], w=4, thr=th((GOOD, None), (WARN, 5), (BAD, 20)),
       desc="Guacamole suele responder 403 a un login incorrecto, y el filtro de red también devuelve 403. Una ráfaga de golpes puede ser un intento de fuerza bruta.")
g.stat("Último backup de la base", [f'time() - max(kube_cronjob_status_last_successful_time{{{NSG}}})'], w=4, unit="s", decimals=1, thr=th((GOOD, None), (WARN, 129600), (BAD, 259200)),
       desc="Tiempo desde el último pg_dump exitoso.")
g.section("Recursos")
g.ts("CPU por pod", [(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{NSG},container!="",container!="POD"}}[{RI}]))', "{{pod}}")], w=8, unit="short", decimals=3)
g.ts("Memoria por pod", [(f'sum by (pod) (container_memory_working_set_bytes{{{NSG},container!="",container!="POD"}})', "{{pod}}")], w=8, unit="bytes")
g.ts("Red por pod", [(f'sum by (pod) (rate(container_network_receive_bytes_total{{{NSG}}}[{RI}]))', "{{pod}} ↓"),
                     (f'sum by (pod) (rate(container_network_transmit_bytes_total{{{NSG}}}[{RI}]))', "{{pod}} ↑")], w=8, unit="Bps",
     overrides=[by_regex(".*↑", prop("custom.transform", "negative-Y"))])
g.section("Tráfico y seguridad")
g.ts("Peticiones por código", [(f'sum by (code) (rate(traefik_service_requests_total{{{GSVC}}}[{RI}]))', "{{code}}")], w=12, stack=True, fill=35, unit="reqps", overrides=CODE_COLORS)
g.ts("Latencia p95", [(f'histogram_quantile(0.95, sum by (le) (rate(traefik_service_request_duration_seconds_bucket{{{GSVC}}}[{RI}])))', "p95")], w=12, unit="s", color=VIOLET)
g.bar("Respuestas por código (última hora)", [(f'sort_desc(sum by (code) (increase(traefik_service_requests_total{{{GSVC}}}[1h])))', "{{code}}")],
      w=12, h=7, mode="gradient", decimals=0, minv=0, color=INFO, no_value="Sin tráfico")
g.ts("Respuestas 403 y 429 (bloqueos y límite de tasa)", [(f'sum(rate(traefik_service_requests_total{{{GSVC},code="403"}}[{RI}]))', "403"),
                                                           (f'sum(rate(traefik_service_requests_total{{{GSVC},code="429"}}[{RI}]))', "429")], w=12, h=7, unit="reqps",
     overrides=[by_name("403", color_of(WARN)), by_name("429", color_of(BAD))])
g.section("Base de datos y backups")
g.bar("Uso de los volúmenes", [(f'sort_desc(kubelet_volume_stats_used_bytes{{{NSG}}} / kubelet_volume_stats_capacity_bytes{{{NSG}}} * 100)', "{{persistentvolumeclaim}}")],
      w=8, h=7, mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 75), (BAD, 90)), no_value="Sin datos de volúmenes")
g.ts("Memoria de postgres", [(f'sum(container_memory_working_set_bytes{{{NSG},pod=~"postgres.*",container!="",container!="POD"}})', "postgres")], w=8, h=7, unit="bytes", color=VIOLET)
g.stat("Último backup de Velero", ["time() - max(velero_backup_last_successful_timestamp)"], w=8, h=7, unit="s", decimals=1, thr=th((GOOD, None), (WARN, 129600), (BAD, 172800)))
g.save(os.path.join(OUT, "guacamole.json"))
print("ok")
PYGEN5
python3 -I "$GEN/phase6b4.py" >/dev/null && ok "k3s y Centro de mando regenerados" || { bad "falló phase6b4"; exit 1; }
python3 -I "$GEN/phase6b5.py" >/dev/null && ok "Servidor, Docker, Plataforma, Apps y Guacamole generados" || { bad "falló phase6b5"; exit 1; }
for f in $NEW; do
  jq -e '.panels|length' "$SRC/$f.json" >/dev/null 2>&1 && ok "$f.json: $(jq '.panels|length' $SRC/$f.json) paneles" || { bad "$f.json inválido"; exit 1; }
done
if [ -f "$SRC/servidor-recursos.json" ]; then rm -f "$SRC/servidor-recursos.json" && ok "servidor-recursos fusionado dentro de 'Servidor y discos' (backup en ~/homelab-backup)"; fi

echo "== 2) ConfigMap (con server-side apply para no chocar con el límite de 256 KiB de last-applied) =="
kubectl create configmap grafana-dashboards -n monitoring --from-file="$SRC" --dry-run=client -o yaml \
  | sed '/^metadata:$/a\  annotations:\n    argocd.argoproj.io/sync-options: ServerSideApply=true' > "$CM" || { bad "no pude generar el ConfigMap"; exit 1; }
grep -q 'ServerSideApply=true' "$CM" && ok "anotación ServerSideApply en el ConfigMap" || { bad "no se pudo anotar el ConfigMap"; cp ~/homelab-backup/configmap-grafana-dashboards.yaml.bak5 "$CM"; exit 1; }
kubectl apply --server-side --dry-run=server -f "$CM" >/dev/null 2>/tmp/dry.err && ok "ConfigMap válido para el cluster ($(wc -c < $CM) bytes)" || { bad "el cluster rechazó el ConfigMap: $(head -c 200 /tmp/dry.err)"; cp ~/homelab-backup/configmap-grafana-dashboards.yaml.bak5 "$CM"; exit 1; }
grep -qiE 'password|secret|token' "$SRC"/*.json && { bad "posible secreto en los JSON"; exit 1; } || ok "sin secretos en los JSON"

echo "== 3) Consultas contra VictoriaMetrics (solo se listan las que fallan o salen vacías) =="
kubectl -n monitoring port-forward svc/victoriametrics 18428:8428 >/tmp/pf.log 2>&1 &
PF=$!; sleep 4; VM=http://127.0.0.1:18428
[ "$(curl -s -o /dev/null -w '%{http_code}' $VM/health)" = "200" ] && ok "VictoriaMetrics responde" || { bad "VictoriaMetrics no responde (ver /tmp/pf.log)"; kill $PF 2>/dev/null; exit 1; }
NSL=$(curl -s -G "$VM/api/v1/label/namespace/values" --data-urlencode 'match[]=kube_pod_info' | jq -r '.data[]')
echo "$NSL" | grep -qx media && ok "namespace 'media' existe (es el valor por defecto de 'Apps y media')" || warn "no existe el namespace 'media': en 'Apps y media' elegí otro"
PODN=$(curl -s -G "$VM/api/v1/label/pod/values" --data-urlencode 'match[]=kube_pod_info{namespace=~".*"}' | jq '.data|length')
[ "${PODN:-0}" -gt 0 ] && ok "variables \$namespace y \$pod con valores ($(echo "$NSL" | wc -l) namespaces, $PODN pods)" || bad "las variables no devuelven valores"
RES=$(mktemp)
for f in $NEW; do
  jq -r '.panels[] | select(.targets) | .title as $t | .targets[] | "\($t)\t\(.expr)"' "$SRC/$f.json" | sed 's/\$__rate_interval/5m/g; s/\$namespace/.*/g; s/\$pod/.*/g' | while IFS=$'\t' read -r t q; do
    r=$(curl -s "$VM/api/v1/query" --data-urlencode "query=$q")
    if [ "$(echo "$r" | jq -r '.status')" != "success" ]; then echo "ERR	$f	$t	$(echo "$r" | jq -r '.error' | cut -c1-100)" >> "$RES"
    elif [ "$(echo "$r" | jq '.data.result|length')" -gt 0 ]; then echo "OK	$f	$t	" >> "$RES"
    else echo "VACIO	$f	$t	" >> "$RES"; fi
  done
done
kill $PF 2>/dev/null
echo "   consultas: $(grep -c '^OK' "$RES") con datos, $(grep -c '^VACIO' "$RES") vacías, $(grep -c '^ERR' "$RES") con error"
grep '^ERR' "$RES" | while IFS=$'\t' read -r _ f t d; do bad "$f · $t: $d"; done
grep '^VACIO' "$RES" | sort -u | while IFS=$'\t' read -r _ f t d; do warn "$f · $t: sin datos"; done
rm -f "$RES"

echo "== 4) Commit, push y ArgoCD =="
git add -A grafana scripts "$CM"
git commit -qm "grafana: 7 dashboards con tema neón como código (servidor, docker, plataforma, apps, guacamole)" && git push -q && ok "push OK" || { bad "falló el push"; exit 1; }
kubectl -n argocd annotate application app-monitoring argocd.argoproj.io/refresh=hard --overwrite >/dev/null
HEAD=$(git rev-parse HEAD); synced=0
for i in $(seq 1 36); do
  S=$(kubectl -n argocd get application app-monitoring -o jsonpath='{.status.sync.status} {.status.sync.revision}')
  [ "$S" = "Synced $HEAD" ] && { synced=1; break; }; sleep 5
done
[ $synced = 1 ] && ok "ArgoCD Synced" || bad "ArgoCD no llegó a Synced (estado: $S). Revisá: kubectl -n argocd get application app-monitoring -o jsonpath='{.status.conditions}'"

echo "== 5) ¿Los carga Grafana? (hasta ~3 min) =="
for f in $NEW; do
  want=$(md5sum "$SRC/$f.json" | cut -d' ' -f1); got=""
  for i in $(seq 1 36); do
    got=$(kubectl -n monitoring exec deploy/grafana -- md5sum /var/lib/grafana/dashboards/$f.json 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$want" ] && break; sleep 5
  done
  [ "$got" = "$want" ] && ok "$f.json ya está en el pod" || bad "$f.json todavía no llegó al pod"
done
U=$(kubectl -n monitoring exec deploy/grafana -- printenv GF_SECURITY_ADMIN_USER 2>/dev/null); P=$(kubectl -n monitoring exec deploy/grafana -- printenv GF_SECURITY_ADMIN_PASSWORD 2>/dev/null)
kubectl -n monitoring port-forward deploy/grafana 13000:3000 >/tmp/pf-gf.log 2>&1 &
PG=$!; sleep 4
for f in $NEW; do
  want=$(jq '[.panels[]]|length' "$SRC/$f.json"); got=0
  for i in $(seq 1 12); do
    got=$(curl -s -u "$U:$P" "http://127.0.0.1:13000/api/dashboards/uid/$f" | jq '.dashboard.panels|length' 2>/dev/null)
    [ "$got" = "$want" ] && break; sleep 5
  done
  [ "$got" = "$want" ] && ok "Grafana sirve $f ($got paneles)" || warn "Grafana sirve $f con ${got:-0} paneles (esperados $want): puede tardar un poco más"
done
echo "   Dashboards que lista Grafana:"
curl -s -u "$U:$P" "http://127.0.0.1:13000/api/search?type=dash-db" | jq -r '.[]|"   - \(.title)"' | sort
kill $PG 2>/dev/null
echo "   Errores de provisioning recientes (vacío = bien):"
kubectl -n monitoring logs deploy/grafana --since=10m 2>&1 | grep -iE 'level=error' | grep -iE 'provision|dashboard' | tail -5 | sed 's/^/   /'
echo
echo ">>> En Grafana abrí el menú 'Dashboards Sparky' (arriba) para moverte entre los 7."
