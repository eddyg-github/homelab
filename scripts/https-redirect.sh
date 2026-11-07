#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
F=platform/traefik/helmchartconfig.yaml
cp "$F" /tmp/helmchartconfig.bak

echo "== 1) Git: redirect web -> websecure =="
python3 - <<'PY'
import yaml
f='platform/traefik/helmchartconfig.yaml'
o=yaml.safe_load(open(f)); v=yaml.safe_load(o['spec']['valuesContent'])
v.setdefault('ports',{}).setdefault('web',{})['redirections']={'entryPoint':{'to':'websecure','scheme':'https','permanent':True}}
o['spec']['valuesContent']=yaml.safe_dump(v,sort_keys=False)
open(f,'w').write(yaml.safe_dump(o,sort_keys=False))
PY
kubectl apply -f "$F" >/dev/null
sleep 30
kubectl -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null 2>&1
sleep 10

echo "== 2) Pruebas =="
IP=192.168.1.47
J=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' --resolve jellyfin.lyxar.dedyn.io:443:$IP https://jellyfin.lyxar.dedyn.io/)
R=$(curl -sk -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' --resolve radarr.lyxar.dedyn.io:80:$IP http://radarr.lyxar.dedyn.io/)
echo "   jellyfin https -> $J"
echo "   radarr http    -> $R  (esperado: 301 https://radarr...)"
case $J in [23]??) ;; *) bad "Jellyfin no responde: revierto"; cp /tmp/helmchartconfig.bak "$F"; kubectl apply -f "$F" >/dev/null; exit 1;; esac
case "$R" in 301*https://*) ok "redirección activa";; *) bad "la redirección no se aplicó (ver salida)";; esac

echo "== 3) Push =="
git add -A; git diff --cached --quiet && echo "  (sin cambios)" || git commit -qm "traefik: redirect global HTTP -> HTTPS"
git push -q && ok "push OK"
