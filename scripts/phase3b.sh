#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
REPO=$(git remote get-url origin)

exp(){ # kind name ns
  kubectl -n "$3" get "$1" "$2" -o json | jq '
    del(.status,.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.metadata.ownerReferences,.metadata.selfLink,.metadata.finalizers,.spec.clusterIP,.spec.clusterIPs,.spec.volumeName)
    | del(.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"])
    | .metadata.annotations=((.metadata.annotations//{})|with_entries(select(.key|test("last-applied|^deployment\\.kubernetes\\.io|^pv\\.kubernetes\\.io|^volume\\.(beta\\.)?kubernetes\\.io")|not)))
    | if (.metadata.annotations|length)==0 then del(.metadata.annotations) else . end
    | if .kind=="Service" then del(.spec.ipFamilies,.spec.ipFamilyPolicy,.spec.internalTrafficPolicy,.spec.sessionAffinity) else . end' \
  | python3 -c 'import sys,json,yaml;print(yaml.safe_dump(json.load(sys.stdin),sort_keys=False))'
}
w(){ # app kind name ns
  mkdir -p "apps/$1"
  exp "$2" "$3" "$4" > "apps/$1/$2-$3.yaml" 2>/dev/null && [ -s "apps/$1/$2-$3.yaml" ] || { bad "no pude exportar $2/$3 ($4)"; rm -f "apps/$1/$2-$3.yaml"; }
}

echo "== 1) Exporto manifiestos vivos a apps/ =="
rm -rf apps/media apps/minio apps/monitoring apps/filebrowser
for n in jellyfin prowlarr qbittorrent radarr sonarr; do w media deployment $n media; w media service $n media; done
w media ingress jellyfin media
for p in jellyfin-cache-pvc jellyfin-config-pvc media-pvc prowlarr-config sonarr-config radarr-config qbittorrent-config; do w media persistentvolumeclaim $p media; done
w minio deployment minio minio; w minio service minio minio; w minio persistentvolumeclaim minio-data minio
for n in grafana otel-collector vmalert; do w monitoring deployment $n monitoring; done
for n in grafana otel-collector victoriametrics; do w monitoring service $n monitoring; done
w monitoring statefulset victoriametrics monitoring
w monitoring ingress grafana monitoring
w monitoring persistentvolumeclaim victoriametrics-data monitoring
for c in grafana-dashboard-providers grafana-dashboards grafana-datasources otel-collector-config vmalert-rules; do w monitoring configmap $c monitoring; done
w filebrowser deployment filebrowser default; w filebrowser service filebrowser default
ok "$(find apps -name '*.yaml' | wc -l) archivos"

echo "== 2) Chequeo de secretos en claro =="
python3 - <<'PY' && ok "sin credenciales en claro" || { echo "  ❌ corregí eso antes de seguir (no se commiteó nada)"; exit 1; }
import yaml,glob,re,sys
bad=[]
def walk(o,f):
    if isinstance(o,dict):
        n=o.get('name')
        if isinstance(n,str) and 'value' in o and re.search(r'PASSWORD|SECRET|TOKEN|_KEY$|_USER$',n,re.I): bad.append((f,n))
        for v in o.values(): walk(v,f)
    elif isinstance(o,list):
        for v in o: walk(v,f)
for f in glob.glob('apps/**/*.yaml',recursive=True): walk(yaml.safe_load(open(f)),f)
for b in bad: print('  ❌ valor sensible en claro:',*b)
sys.exit(1 if bad else 0)
PY

echo "== 3) Dry-run contra el cluster =="
if kubectl apply --dry-run=server -R -f apps/ >/tmp/dry.txt 2>&1; then ok "los manifiestos son válidos"; else cat /tmp/dry.txt | head -20; bad "dry-run falló, no se commitea"; exit 1; fi

echo "== 4) AppSet para apps/* y push =="
cat > bootstrap/appset-apps.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: apps
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: $REPO
        revision: main
        directories:
          - path: apps/*
  template:
    metadata:
      name: 'app-{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: $REPO
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: false, selfHeal: true }
        syncOptions: [ServerSideApply=true]
YAML
sed -i '/observabilidad/d' README.md; rmdir monitoring 2>/dev/null
git add -A && git commit -qm "apps: media, minio, monitoring, filebrowser exportados desde el cluster" && git push -q && ok "push OK" || { bad "push falló"; exit 1; }
kubectl apply -f bootstrap/appset-apps.yaml >/dev/null && ok "ApplicationSet aplicado"

echo "== 5) Esperando que ArgoCD sincronice (máx 6 min) =="
for i in $(seq 1 24); do
  A=$(kubectl -n argocd get applications.argoproj.io --no-headers -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status 2>/dev/null | grep '^app-')
  B=$(echo "$A" | awk '$2!="Synced"||$3!="Healthy"')
  [ "$(echo "$A" | grep -c .)" -ge 4 ] && [ -z "$B" ] && break
  for a in $(kubectl -n argocd get applications.argoproj.io -o name | grep '/app-'); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  sleep 15
done
echo "$A"
