import json
G, O, R = "green", "orange", "red"


def steps(*p):
    out = [{"color": p[0][0], "value": None}]
    for c, v in p[1:]:
        out.append({"color": c, "value": v})
    return out


class Dash:
    def __init__(self, title, uid, tags):
        self.n = 0
        self.d = {"title": title, "uid": uid, "schemaVersion": 39, "version": 1,
                  "editable": True, "refresh": "30s", "time": {"from": "now-6h", "to": "now"},
                  "tags": tags, "panels": []}

    def _p(self, ptype, title, targets, x, y, w, h, unit=None, desc="", th=None,
           mappings=None, options=None, minv=None, maxv=None, decimals=None, stack=False, transformations=None):
        self.n += 1
        ts = []
        for i, t in enumerate(targets):
            if isinstance(t, str):
                t = (t, None)
            tt = {"expr": t[0], "refId": chr(65 + i)}
            if t[1]:
                tt["legendFormat"] = t[1]
            if ptype in ("stat", "bargauge", "table"):
                tt["instant"] = True
            if ptype == "table":
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
        if th:
            dfl["thresholds"] = {"mode": "absolute", "steps": th}
            dfl["color"] = {"mode": "thresholds"}
        if mappings:
            dfl["mappings"] = mappings
        if stack:
            dfl["custom"] = {"stacking": {"mode": "normal"}, "fillOpacity": 30}
        p = {"id": self.n, "type": ptype, "title": title, "description": desc,
             "gridPos": {"x": x, "y": y, "w": w, "h": h}, "targets": ts,
             "fieldConfig": {"defaults": dfl, "overrides": []}}
        if options:
            p["options"] = options
        if transformations:
            p["transformations"] = transformations
        self.d["panels"].append(p)

    def stat(self, title, targets, x, y, w=4, h=4, named=False, **kw):
        opt = {"colorMode": "background" if kw.get("th") else "none",
               "textMode": "value_and_name" if named else "auto",
               "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}}
        self._p("stat", title, targets, x, y, w, h, options=opt, **kw)

    def ts(self, title, targets, x, y, w=12, h=8, **kw):
        self._p("timeseries", title, targets, x, y, w, h, **kw)

    def bar(self, title, targets, x, y, w=12, h=8, **kw):
        opt = {"orientation": "horizontal", "displayMode": "gradient",
               "reduceOptions": {"calcs": ["lastNotNull"]}}
        self._p("bargauge", title, targets, x, y, w, h, options=opt, **kw)

    def table(self, title, targets, x, y, w=12, h=8, hide=("Time", "__name__", "job", "instance", "node"), **kw):
        tr = [{"id": "organize", "options": {"excludeByName": {k: True for k in hide}}}]
        self._p("table", title, targets, x, y, w, h, options={"showHeader": True}, transformations=tr, **kw)

    def save(self, path):
        json.dump(self.d, open(path, "w"), indent=2, ensure_ascii=False)
