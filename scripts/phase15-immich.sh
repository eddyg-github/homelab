#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
CN=sealed-secrets-controller; CNS=kube-system; A=apps/immich; HOST=immich.lyxar.dedyn.io; DATA=/mnt/media3/immich; V=v3.4.1
rand(){ head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 28; }
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  kubectl -n argocd annotate applicationset apps argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1; }

echo "== 0) Pre-chequeos y carpeta =="
kubectl -n $CNS get deploy $CN >/dev/null 2>&1 && ok "Sealed Secrets" || { bad "falta Sealed Secrets"; exit 1; }
FREE=$(df -BG --output=avail /mnt/media3 | tail -1 | tr -dc 0-9); [ "$FREE" -ge 50 ] && ok "/mnt/media3: ${FREE}G libres" || { bad "poco espacio"; exit 1; }
sudo mkdir -p $DATA && sudo chown 1000:1000 $DATA && sudo chmod 750 $DATA && ok "$DATA"
[ -s sealed-secrets-pub.crt ] || kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt
mkdir -p $A

echo "== 1) Secreto =="
if [ -s $A/sealedsecret-im-env.yaml ]; then ok "ya existe, lo reutilizo"; PG=""
else
  PG=$(rand)
  PG=$PG jq -n '{apiVersion:"v1",kind:"Secret",metadata:{name:"im-env",namespace:"immich"},type:"Opaque",data:{POSTGRES_USER:("immich"|@base64),POSTGRES_DB:("immich"|@base64),POSTGRES_PASSWORD:(env.PG|@base64),DB_PASSWORD:(env.PG|@base64)}}' \
   | kubeseal --cert sealed-secrets-pub.crt --format yaml > $A/sealedsecret-im-env.yaml && [ -s $A/sealedsecret-im-env.yaml ] && ok "cifrado" || { bad "no pude cifrar"; exit 1; }
fi

echo "== 2) Manifiestos =="
cat > $A/namespace.yaml <<'Y'
apiVersion: v1
kind: Namespace
metadata: {name: immich}
Y
cat > $A/db.yaml <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: im-pgdata, namespace: immich}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 5Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: im-postgres, namespace: immich}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: im-postgres}}
  template:
    metadata: {labels: {app: im-postgres}}
    spec:
      containers:
        - name: postgres
          image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
          ports: [{containerPort: 5432}]
          env: [{name: PGDATA, value: /var/lib/postgresql/data/pgdata}, {name: POSTGRES_INITDB_ARGS, value: "--data-checksums"}]
          envFrom: [{secretRef: {name: im-env}}]
          readinessProbe: {exec: {command: [sh, -c, 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"']}, periodSeconds: 10, failureThreshold: 18}
          resources: {requests: {cpu: 50m, memory: 256Mi}, limits: {memory: 1Gi}}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
      volumes: [{name: data, persistentVolumeClaim: {claimName: im-pgdata}}]
---
apiVersion: v1
kind: Service
metadata: {name: im-postgres, namespace: immich}
spec: {selector: {app: im-postgres}, ports: [{name: pg, port: 5432, targetPort: 5432}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: im-valkey, namespace: immich}
spec:
  replicas: 1
  selector: {matchLabels: {app: im-valkey}}
  template:
    metadata: {labels: {app: im-valkey}}
    spec:
      containers:
        - name: valkey
          image: docker.io/valkey/valkey:9
          args: ["--save", "", "--appendonly", "no", "--maxmemory", "128mb", "--maxmemory-policy", "allkeys-lru"]
          ports: [{containerPort: 6379}]
          readinessProbe: {tcpSocket: {port: 6379}, periodSeconds: 10}
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 192Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: im-valkey, namespace: immich}
spec: {selector: {app: im-valkey}, ports: [{name: redis, port: 6379, targetPort: 6379}]}
Y
cat > $A/immich.yaml <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: immich-server, namespace: immich}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: immich-server}}
  template:
    metadata: {labels: {app: immich-server}}
    spec:
      initContainers:
        - name: wait-db
          image: busybox:1.36
          command: [sh, -c, "until nc -z im-postgres 5432 && nc -z im-valkey 6379; do sleep 3; done"]
      containers:
        - name: server
          image: ghcr.io/immich-app/immich-server:$V
          ports: [{containerPort: 2283}]
          env:
            - {name: DB_HOSTNAME, value: im-postgres}
            - {name: DB_USERNAME, value: immich}
            - {name: DB_DATABASE_NAME, value: immich}
            - {name: REDIS_HOSTNAME, value: im-valkey}
            - {name: IMMICH_MACHINE_LEARNING_ENABLED, value: "false"}
            - {name: TZ, value: America/Argentina/Buenos_Aires}
            - {name: DB_PASSWORD, valueFrom: {secretKeyRef: {name: im-env, key: DB_PASSWORD}}}
          readinessProbe: {httpGet: {path: /api/server/ping, port: 2283}, periodSeconds: 15, failureThreshold: 40}
          resources: {requests: {cpu: 100m, memory: 512Mi}, limits: {memory: 2Gi}}
          volumeMounts: [{name: upload, mountPath: /data}]
      volumes: [{name: upload, hostPath: {path: /mnt/media3/immich, type: Directory}}]
---
apiVersion: v1
kind: Service
metadata: {name: immich-server, namespace: immich}
spec: {selector: {app: immich-server}, ports: [{name: http, port: 2283, targetPort: 2283}]}
Y
cat > $A/dbtools.yaml <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: im-dumps, namespace: immich}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 2Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: im-dumps-holder, namespace: immich}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: im-dumps-holder}}
  template:
    metadata:
      labels: {app: im-dumps-holder}
      annotations: {backup.velero.io/backup-volumes: dumps}
    spec:
      containers:
        - name: holder
          image: busybox:1.36
          command: [sh, -c, "while true; do sleep 3600; done"]
          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {memory: 32Mi}}
          volumeMounts: [{name: dumps, mountPath: /dumps}]
      volumes: [{name: dumps, persistentVolumeClaim: {claimName: im-dumps}}]
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: im-pgdump, namespace: immich}
spec:
  schedule: "45 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata: {labels: {app: im-dbtools}}
        spec:
          restartPolicy: OnFailure
          containers:
            - name: dump
              image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
              env:
                - {name: PGHOST, value: im-postgres}
                - {name: PGUSER, valueFrom: {secretKeyRef: {name: im-env, key: POSTGRES_USER}}}
                - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: im-env, key: POSTGRES_PASSWORD}}}
                - {name: PGDATABASE, valueFrom: {secretKeyRef: {name: im-env, key: POSTGRES_DB}}}
              command: [/bin/sh, -c]
              args:
                - |
                  set -e
                  F=/dumps/immich-$(date +%F).sql
                  pg_dump > "$F"; gzip -f "$F"
                  find /dumps -name 'immich-*.sql.gz' -mtime +7 -delete
                  ls -la /dumps
              resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 256Mi}}
              volumeMounts: [{name: dumps, mountPath: /dumps}]
          volumes: [{name: dumps, persistentVolumeClaim: {claimName: im-dumps}}]
Y
cat > $A/middlewares.yaml <<'Y'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: lan-only, namespace: immich}
spec:
  ipAllowList:
    sourceRange: ["192.168.1.0/24", "100.64.0.0/10", "127.0.0.1/32", "10.8.0.0/24"]
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: ratelimit, namespace: immich}
spec:
  rateLimit: {average: 100, period: 1s, burst: 200}
Y
cat > $A/ingress.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: immich
  namespace: immich
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: immich-lan-only@kubernetescrd,immich-ratelimit@kubernetescrd
spec:
  ingressClassName: traefik
  tls: [{hosts: [immich.lyxar.dedyn.io], secretName: immich-tls}]
  rules:
    - host: immich.lyxar.dedyn.io
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: immich-server, port: {number: 2283}}}}
Y
cat > $A/networkpolicy.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress, namespace: immich}
spec: {podSelector: {}, policyTypes: [Ingress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: traefik-to-immich, namespace: immich}
spec:
  podSelector: {matchLabels: {app: immich-server}}
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
      ports: [{port: 2283}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: traefik-to-acme-solver, namespace: immich}
spec:
  podSelector: {matchLabels: {acme.cert-manager.io/http01-solver: "true"}}
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
      ports: [{port: 8089}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: to-postgres, namespace: immich}
spec:
  podSelector: {matchLabels: {app: im-postgres}}
  ingress:
    - from: [{podSelector: {matchExpressions: [{key: app, operator: In, values: [immich-server, im-dbtools]}]}}]
      ports: [{port: 5432}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: to-valkey, namespace: immich}
spec:
  podSelector: {matchLabels: {app: im-valkey}}
  ingress:
    - from: [{podSelector: {matchLabels: {app: immich-server}}}]
      ports: [{port: 6379}]
Y
ok "manifiestos escritos"

echo "== 3) Velero, fugas, dry-run, push =="
python3 - <<'PY' || { echo "  ❌ falló la edición de Velero"; exit 1; }
import os,yaml
p=os.path.expanduser('~/homelab/platform/velero/velero.yaml'); docs=[d for d in yaml.safe_load_all(open(p)) if d]
for d in docs:
    if d.get('kind')=='Schedule':
        ns=d['spec']['template']['includedNamespaces']
        if 'immich' not in ns: ns.append('immich')
yaml.safe_dump_all(docs,open(p,'w'),sort_keys=False)
PY
[ -n "$PG" ] && grep -rqF --exclude-dir=.git -- "$PG" . && { bad "contraseña en claro en el repo"; exit 1; }
ok "sin secretos en claro"
cat > docs/IMMICH.md <<'MD'
# Immich
- Namespace `immich`: server (ML desactivado) + postgres (VectorChord) + valkey. https://immich.lyxar.dedyn.io (solo LAN/VPN).
- Fotos: hostPath `/mnt/media3/immich` (NO en Velero; respaldar aparte). Base: CronJob `im-pgdump` -> PVC `im-dumps` (Velero).
- Actualizar: cambiar el tag de immich-server y la imagen de postgres siguiendo las notas de la release.
MD
kubectl create ns immich --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply --dry-run=server -f $A/ >/tmp/dry15.txt 2>&1 && ok "manifiestos válidos" || { head -12 /tmp/dry15.txt; bad "dry-run falló"; exit 1; }
git add -A; git diff --cached --quiet || git commit -qm "immich: despliegue (LAN/VPN, sin ML), postgres vectorchord, valkey, pg_dump, velero"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh

echo "== 4) Esperando (máx 20 min) =="
for i in $(seq 1 60); do kubectl -n immich get deploy immich-server >/dev/null 2>&1 && break; refresh; sleep 10; done
for d in im-postgres im-valkey; do kubectl -n immich rollout status deploy/$d --timeout=420s >/dev/null 2>&1 && ok "$d Ready" || { bad "$d no Ready"; kubectl -n immich logs deploy/$d --tail=10 2>&1; exit 1; }; done
kubectl -n immich rollout status deploy/immich-server --timeout=1200s >/dev/null 2>&1 && ok "immich-server Ready" || { bad "immich-server no Ready"; kubectl -n immich logs deploy/immich-server --tail=25 2>&1 | cut -c1-220; exit 1; }
for i in $(seq 1 30); do [ "$(kubectl -n immich get certificate immich-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break; sleep 10; done
[ "$(kubectl -n immich get certificate immich-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && ok "certificado emitido" || { bad "certificado pendiente. NO borres nada. Motivo:"; kubectl -n immich describe challenge 2>/dev/null | grep Reason | head -2 | cut -c1-250; }
echo "   desde el servidor (403 = filtro LAN): $(curl -s -o /dev/null -m 10 --resolve $HOST:443:192.168.1.47 -w '%{http_code}' https://$HOST/)"
kubectl -n argocd get applications.argoproj.io app-immich --no-headers
echo ">>> Agregá $HOST al hosts, abrí la web y creá el administrador con eduardoghidoli@gmail.com"
