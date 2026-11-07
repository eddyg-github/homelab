#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab

echo "== 1) Git: AllowedHosts=* en sonarr, radarr, prowlarr =="
python3 - <<'PY'
import yaml
for n in ('sonarr','radarr','prowlarr'):
    f=f'apps/media/deployment-{n}.yaml'; o=yaml.safe_load(open(f))
    c=o['spec']['template']['spec']['containers'][0]
    env={e['name']:e for e in c.get('env',[])}
    env['AllowedHosts']={'name':'AllowedHosts','value':'*'}
    c['env']=list(env.values()); open(f,'w').write(yaml.safe_dump(o,sort_keys=False)); print('  ',f)
PY
git add -A
git diff --cached --quiet && echo "  (sin cambios)" || git commit -qm "fix: AllowedHosts=* en sonarr/radarr/prowlarr"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }

echo "== 2) Esperando a ArgoCD =="
for i in $(seq 1 24); do
  for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  kubectl -n media get deploy sonarr -o json | jq -e '[.spec.template.spec.containers[0].env[]?|select(.name=="AllowedHosts")]|length>0' >/dev/null && break
  sleep 15
done
for d in sonarr radarr prowlarr; do
  kubectl -n media rollout status deploy/$d --timeout=240s >/dev/null 2>&1 && ok "$d Ready" || bad "$d no quedó Ready"
done
sleep 20

echo "== 3) Prueba: cabecera Host real contra cada app (dentro del pod) =="
for p in sonarr:8989 radarr:7878 prowlarr:9696; do
  n=${p%%:*}; port=${p##*:}
  echo "   $n -> $(kubectl -n media exec deploy/$n -- curl -s -o /dev/null -m 10 -H "Host: $n.lyxar.dedyn.io" -w '%{http_code}' http://localhost:$port/)  (200/301/302 = bien, 400 = sigue el problema)"
done
echo "== 4) qBittorrent =="
echo "   $(kubectl -n media exec deploy/qbittorrent -- curl -s -m 10 -H 'Host: qbittorrent.lyxar.dedyn.io' -w ' http=%{http_code}' http://localhost:8080/ | tail -c 80)"
