#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
CN=sealed-secrets-controller; CNS=kube-system; A=apps/nextcloud; HOST=nextcloud.lyxar.dedyn.io; DATA=/mnt/media3/nextcloud
rand(){ head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 28; }
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  kubectl -n argocd annotate applicationset apps argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1; }
occ(){ kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c "php occ $*"; }

echo "== 0) Pre-chequeos y carpeta de datos =="
kubectl -n $CNS get deploy $CN >/dev/null 2>&1 && ok "Sealed Secrets" || { bad "falta Sealed Secrets"; exit 1; }
findmnt -n /mnt/media3 >/dev/null && ok "/mnt/media3 montado" || { bad "/mnt/media3 no está montado"; exit 1; }
FREE=$(df -BG --output=avail /mnt/media3 | tail -1 | tr -dc 0-9); [ "$FREE" -ge 50 ] && ok "/mnt/media3: ${FREE}G libres" || { bad "poco espacio"; exit 1; }
sudo mkdir -p $DATA && sudo chown 33:33 $DATA && sudo chmod 750 $DATA && ok "$DATA (dueño www-data)"
[ -s sealed-secrets-pub.crt ] || kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt
mkdir -p $A docs

echo "== 1) Secretos =="
if [ -s $A/sealedsecret-nc-env.yaml ]; then ok "SealedSecret ya existe, lo reutilizo"; PG=""; AD=""
else
  PG=$(rand); AD=$(rand)
  PG=$PG AD=$AD jq -n '{apiVersion:"v1",kind:"Secret",metadata:{name:"nc-env",namespace:"nextcloud"},type:"Opaque",data:{POSTGRES_USER:("nextcloud"|@base64),POSTGRES_DB:("nextcloud"|@base64),POSTGRES_PASSWORD:(env.PG|@base64),NEXTCLOUD_ADMIN_USER:("edu"|@base64),NEXTCLOUD_ADMIN_PASSWORD:(env.AD|@base64)}}' \
   | kubeseal --cert sealed-secrets-pub.crt --format yaml > $A/sealedsecret-nc-env.yaml && [ -s $A/sealedsecret-nc-env.yaml ] && ok "cifrado" || { bad "no pude cifrar"; exit 1; }
  ( umask 077; printf 'Nextcloud  https://%s  usuario: edu  contraseña: %s\n' "$HOST" "$AD" >> ~/homelab-backup/new-credentials.txt )
  ok "contraseña de admin guardada en ~/homelab-backup/new-credentials.txt"
fi

echo "== 2) Manifiestos =="
cat > $A/namespace.yaml <<'Y'
apiVersion: v1
kind: Namespace
metadata: {name: nextcloud}
Y
cat > $A/postgres-redis.yaml <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: nc-pgdata, namespace: nextcloud}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 5Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: nc-postgres, namespace: nextcloud}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: nc-postgres}}
  template:
    metadata: {labels: {app: nc-postgres}}
    spec:
      securityContext: {fsGroup: 70, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: postgres
          image: postgres:16-alpine
          securityContext: {runAsUser: 70, runAsNonRoot: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          ports: [{containerPort: 5432}]
          env: [{name: PGDATA, value: /var/lib/postgresql/data/pgdata}]
          envFrom: [{secretRef: {name: nc-env}}]
          readinessProbe: {exec: {command: [sh, -c, 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"']}, periodSeconds: 10, failureThreshold: 12}
          resources: {requests: {cpu: 20m, memory: 128Mi}, limits: {memory: 512Mi}}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
      volumes: [{name: data, persistentVolumeClaim: {claimName: nc-pgdata}}]
---
apiVersion: v1
kind: Service
metadata: {name: nc-postgres, namespace: nextcloud}
spec: {selector: {app: nc-postgres}, ports: [{name: pg, port: 5432, targetPort: 5432}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: nc-redis, namespace: nextcloud}
spec:
  replicas: 1
  selector: {matchLabels: {app: nc-redis}}
  template:
    metadata: {labels: {app: nc-redis}}
    spec:
      securityContext: {seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: redis
          image: redis:7-alpine
          args: ["--save", "", "--appendonly", "no", "--maxmemory", "96mb", "--maxmemory-policy", "allkeys-lru"]
          securityContext: {runAsUser: 999, runAsNonRoot: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          ports: [{containerPort: 6379}]
          readinessProbe: {tcpSocket: {port: 6379}, periodSeconds: 10}
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 160Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: nc-redis, namespace: nextcloud}
spec: {selector: {app: nc-redis}, ports: [{name: redis, port: 6379, targetPort: 6379}]}
Y
cat > $A/nextcloud.yaml <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: nc-html, namespace: nextcloud}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 4Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: nextcloud, namespace: nextcloud}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: nextcloud}}
  template:
    metadata:
      labels: {app: nextcloud}
      annotations: {backup.velero.io/backup-volumes: html}
    spec:
      securityContext: {seccompProfile: {type: RuntimeDefault}}
      initContainers:
        - name: wait-db
          image: busybox:1.36
          command: [sh, -c, "until nc -z nc-postgres 5432 && nc -z nc-redis 6379; do sleep 3; done"]
      containers:
        - name: nextcloud
          image: nextcloud:apache
          ports: [{containerPort: 80}]
          env:
            - {name: POSTGRES_HOST, value: nc-postgres}
            - {name: REDIS_HOST, value: nc-redis}
            - {name: NEXTCLOUD_TRUSTED_DOMAINS, value: nextcloud.lyxar.dedyn.io}
            - {name: OVERWRITEHOST, value: nextcloud.lyxar.dedyn.io}
            - {name: OVERWRITEPROTOCOL, value: https}
            - {name: TRUSTED_PROXIES, value: 10.42.0.0/16}
            - {name: PHP_MEMORY_LIMIT, value: 512M}
            - {name: PHP_UPLOAD_LIMIT, value: 10G}
          envFrom: [{secretRef: {name: nc-env}}]
          readinessProbe: {tcpSocket: {port: 80}, periodSeconds: 10, failureThreshold: 120}
          resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 1Gi}}
          volumeMounts:
            - {name: html, mountPath: /var/www/html}
            - {name: data, mountPath: /var/www/html/data}
        - name: cron
          image: nextcloud:apache
          securityContext: {runAsUser: 33, runAsGroup: 33}
          command: [sh, -c, "while true; do sleep 300; [ -f /var/www/html/config/config.php ] && php -f /var/www/html/cron.php; done"]
          resources: {requests: {cpu: 5m, memory: 64Mi}, limits: {memory: 256Mi}}
          volumeMounts:
            - {name: html, mountPath: /var/www/html}
            - {name: data, mountPath: /var/www/html/data}
      volumes:
        - {name: html, persistentVolumeClaim: {claimName: nc-html}}
        - {name: data, hostPath: {path: /mnt/media3/nextcloud, type: Directory}}
---
apiVersion: v1
kind: Service
metadata: {name: nextcloud, namespace: nextcloud}
spec: {selector: {app: nextcloud}, ports: [{name: http, port: 80, targetPort: 80}]}
Y
cat > $A/dbtools.yaml <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: nc-dumps, namespace: nextcloud}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 2Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: nc-dumps-holder, namespace: nextcloud}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: nc-dumps-holder}}
  template:
    metadata:
      labels: {app: nc-dumps-holder}
      annotations: {backup.velero.io/backup-volumes: dumps}
    spec:
      containers:
        - name: holder
          image: busybox:1.36
          command: [sh, -c, "while true; do sleep 3600; done"]
          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {memory: 32Mi}}
          volumeMounts: [{name: dumps, mountPath: /dumps}]
      volumes: [{name: dumps, persistentVolumeClaim: {claimName: nc-dumps}}]
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: nc-pgdump, namespace: nextcloud}
spec:
  schedule: "30 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata: {labels: {app: nc-dbtools}}
        spec:
          restartPolicy: OnFailure
          containers:
            - name: dump
              image: postgres:16-alpine
              env:
                - {name: PGHOST, value: nc-postgres}
                - {name: PGUSER, valueFrom: {secretKeyRef: {name: nc-env, key: POSTGRES_USER}}}
                - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: nc-env, key: POSTGRES_PASSWORD}}}
                - {name: PGDATABASE, valueFrom: {secretKeyRef: {name: nc-env, key: POSTGRES_DB}}}
              command: [/bin/sh, -c]
              args:
                - |
                  set -e
                  F=/dumps/nextcloud-$(date +%F).sql
                  pg_dump > "$F"; gzip -f "$F"
                  find /dumps -name 'nextcloud-*.sql.gz' -mtime +7 -delete
                  ls -la /dumps
              resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
              volumeMounts: [{name: dumps, mountPath: /dumps}]
          volumes: [{name: dumps, persistentVolumeClaim: {claimName: nc-dumps}}]
Y
cat > $A/middlewares.yaml <<'Y'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: lan-only, namespace: nextcloud}
spec:
  ipAllowList:
    sourceRange: ["192.168.1.0/24", "100.64.0.0/10", "127.0.0.1/32", "10.8.0.0/24"]
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: ratelimit, namespace: nextcloud}
spec:
  rateLimit: {average: 100, period: 1s, burst: 200}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: headers, namespace: nextcloud}
spec:
  headers: {stsSeconds: 31536000, forceSTSHeader: true, contentTypeNosniff: true, referrerPolicy: no-referrer}
Y
cat > $A/ingress.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nextcloud
  namespace: nextcloud
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: nextcloud-lan-only@kubernetescrd,nextcloud-ratelimit@kubernetescrd,nextcloud-headers@kubernetescrd
spec:
  ingressClassName: traefik
  tls: [{hosts: [nextcloud.lyxar.dedyn.io], secretName: nextcloud-tls}]
  rules:
    - host: nextcloud.lyxar.dedyn.io
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: nextcloud, port: {number: 80}}}}
Y
cat > $A/networkpolicy.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress, namespace: nextcloud}
spec: {podSelector: {}, policyTypes: [Ingress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: traefik-to-nextcloud, namespace: nextcloud}
spec:
  podSelector: {matchLabels: {app: nextcloud}}
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
      ports: [{port: 80}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: traefik-to-acme-solver, namespace: nextcloud}
spec:
  podSelector: {matchLabels: {acme.cert-manager.io/http01-solver: "true"}}
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
      ports: [{port: 8089}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: to-postgres, namespace: nextcloud}
spec:
  podSelector: {matchLabels: {app: nc-postgres}}
  ingress:
    - from: [{podSelector: {matchExpressions: [{key: app, operator: In, values: [nextcloud, nc-dbtools]}]}}]
      ports: [{port: 5432}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: to-redis, namespace: nextcloud}
spec:
  podSelector: {matchLabels: {app: nc-redis}}
  ingress:
    - from: [{podSelector: {matchLabels: {app: nextcloud}}}]
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
        if 'nextcloud' not in ns: ns.append('nextcloud')
yaml.safe_dump_all(docs,open(p,'w'),sort_keys=False)
PY
for v in "$PG" "$AD"; do [ -n "$v" ] && grep -rqF --exclude-dir=.git -- "$v" . && { bad "una contraseña aparece en claro en el repo"; exit 1; }; done
ok "sin secretos en claro"
cat > docs/NEXTCLOUD.md <<'MD'
# Nextcloud
- Namespace `nextcloud`: nextcloud (apache) + postgres + redis. URL: https://nextcloud.lyxar.dedyn.io (solo LAN/VPN).
- Datos de usuarios: hostPath `/mnt/media3/nextcloud` (NO en Velero; respaldar aparte). Configuración: PVC `nc-html` (Velero). Base: CronJob `nc-pgdump` -> PVC `nc-dumps` (Velero).
- Restaurar la base: `gunzip -c nextcloud-FECHA.sql.gz | kubectl -n nextcloud exec -i deploy/nc-postgres -- psql -U nextcloud nextcloud`.
- Actualizar: cambiar el tag de la imagen UNA versión mayor por vez; nunca saltar versiones mayores.
MD
kubectl create ns nextcloud --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply --dry-run=server -f $A/ >/tmp/dry13.txt 2>&1 && ok "manifiestos válidos" || { head -12 /tmp/dry13.txt; bad "dry-run falló, no se publica"; exit 1; }
git add -A; git diff --cached --quiet || git commit -qm "nextcloud: despliegue (LAN/VPN), postgres, redis, pg_dump, velero"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh

echo "== 4) Esperando (la primera instalación es lenta en este CPU; máx 20 min) =="
for i in $(seq 1 60); do kubectl -n nextcloud get deploy nextcloud >/dev/null 2>&1 && break; refresh; sleep 10; done
for d in nc-postgres nc-redis; do kubectl -n nextcloud rollout status deploy/$d --timeout=300s >/dev/null 2>&1 && ok "$d Ready" || { bad "$d no Ready"; kubectl -n nextcloud logs deploy/$d --tail=8 2>&1; exit 1; }; done
kubectl -n nextcloud rollout status deploy/nextcloud --timeout=1200s >/dev/null 2>&1 && ok "nextcloud Ready (instalación terminada)" || { bad "nextcloud no Ready"; kubectl -n nextcloud get pods; kubectl -n nextcloud logs deploy/nextcloud -c nextcloud --tail=15 2>&1; exit 1; }

echo "== 5) Ajustes con occ =="
occ background:cron >/dev/null 2>&1 && ok "tareas en segundo plano por cron" || bad "no pude activar cron"
occ config:system:set default_phone_region --value=AR >/dev/null 2>&1 && ok "región telefónica AR"
echo "   estado: $(occ status --output=json 2>/dev/null | jq -c '{installed,version:.versionstring,maintenance}')"
MAJOR=$(occ status --output=json 2>/dev/null | jq -r '.version' | cut -d. -f1)
if [[ "$MAJOR" =~ ^[0-9]+$ ]]; then
  sed -i "s#image: nextcloud:apache#image: nextcloud:${MAJOR}-apache#" $A/nextcloud.yaml
  git add -A; git commit -qm "nextcloud: fijar version mayor ${MAJOR}"; git push -q && ok "imagen fijada a nextcloud:${MAJOR}-apache (el pod se reinicia una vez)"
  refresh; sleep 30; kubectl -n nextcloud rollout status deploy/nextcloud --timeout=600s >/dev/null 2>&1 && ok "nextcloud Ready con la imagen fijada" || bad "nextcloud no Ready tras fijar la versión"
fi

echo "== 6) Certificado (sin reintentos manuales: cuida el cupo de Let's Encrypt) =="
for i in $(seq 1 30); do [ "$(kubectl -n nextcloud get certificate nextcloud-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break; sleep 10; done
if [ "$(kubectl -n nextcloud get certificate nextcloud-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; then ok "certificado emitido"
else bad "certificado pendiente. NO borres nada. Motivo:"; kubectl -n nextcloud describe challenge 2>/dev/null | grep -E 'Reason|State' | head -3 | cut -c1-250; fi
echo "   desde el servidor (403 = filtro LAN activo): $(curl -s -o /dev/null -m 10 --resolve $HOST:443:192.168.1.47 -w '%{http_code}' https://$HOST/)"
kubectl -n argocd get applications.argoproj.io app-nextcloud --no-headers
echo; echo ">>> Agregá $HOST al hosts de tu PC (192.168.1.47) y entrá como 'edu'. La contraseña está en ~/homelab-backup/new-credentials.txt"
