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
