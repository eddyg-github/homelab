#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
CN=sealed-secrets-controller; CNS=kube-system; A=apps/vaultwarden; HOST=vaultwarden.lyxar.dedyn.io
rand(){ head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40; }
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  kubectl -n argocd annotate applicationset apps argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1; }

echo "== 0) Pre-chequeos =="
kubectl -n $CNS get deploy $CN >/dev/null 2>&1 && ok "Sealed Secrets" || { bad "falta Sealed Secrets"; exit 1; }
[ -s sealed-secrets-pub.crt ] || kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt
mkdir -p $A

echo "== 1) Secret (token de admin) =="
if [ -s $A/sealedsecret-vw.yaml ]; then ok "SealedSecret ya existe, lo reutilizo"; TOKEN=""
else
  TOKEN=$(rand)
  jq -n --arg t "$TOKEN" '{apiVersion:"v1",kind:"Secret",metadata:{name:"vw-env",namespace:"vaultwarden"},type:"Opaque",data:{ADMIN_TOKEN:($t|@base64)}}' \
   | kubeseal --cert sealed-secrets-pub.crt --format yaml > $A/sealedsecret-vw.yaml && [ -s $A/sealedsecret-vw.yaml ] && ok "cifrado" || { bad "no pude cifrar"; exit 1; }
  ( umask 077; printf 'Vaultwarden admin token (https://%s/admin): %s\n' "$HOST" "$TOKEN" >> ~/homelab-backup/new-credentials.txt )
  ok "token guardado en ~/homelab-backup/new-credentials.txt"
fi

echo "== 2) Manifiestos =="
cat > $A/namespace.yaml <<'Y'
apiVersion: v1
kind: Namespace
metadata: {name: vaultwarden}
Y
cat > $A/vaultwarden.yaml <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: vw-data, namespace: vaultwarden}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 1Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: vaultwarden, namespace: vaultwarden}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: vaultwarden}}
  template:
    metadata:
      labels: {app: vaultwarden}
      annotations: {backup.velero.io/backup-volumes: data}
    spec:
      securityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: vaultwarden
          image: vaultwarden/server:latest
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          ports: [{containerPort: 8080}]
          env:
            - {name: ROCKET_PORT, value: "8080"}
            - {name: DOMAIN, value: "https://vaultwarden.lyxar.dedyn.io"}
            - {name: SIGNUPS_ALLOWED, value: "true"}
            - {name: INVITATIONS_ALLOWED, value: "false"}
            - {name: ADMIN_TOKEN, valueFrom: {secretKeyRef: {name: vw-env, key: ADMIN_TOKEN}}}
          readinessProbe: {httpGet: {path: /alive, port: 8080}, periodSeconds: 10, failureThreshold: 12}
          resources: {requests: {cpu: 20m, memory: 64Mi}, limits: {memory: 256Mi}}
          volumeMounts: [{name: data, mountPath: /data}]
      volumes: [{name: data, persistentVolumeClaim: {claimName: vw-data}}]
---
apiVersion: v1
kind: Service
metadata: {name: vaultwarden, namespace: vaultwarden}
spec: {selector: {app: vaultwarden}, ports: [{name: http, port: 8080, targetPort: 8080}]}
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: vw-sqlite-backup, namespace: vaultwarden}
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          securityContext: {fsGroup: 1000}
          containers:
            - name: backup
              image: alpine:3.20
              command: [/bin/sh, -c]
              args:
                - |
                  set -e
                  apk add --no-cache sqlite >/dev/null
                  mkdir -p /data/backups
                  sqlite3 /data/db.sqlite3 ".backup '/data/backups/db-$(date +%F).sqlite3'"
                  find /data/backups -name 'db-*.sqlite3' -mtime +7 -delete
                  chown -R 1000:1000 /data/backups
                  ls -la /data/backups
              resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
              volumeMounts: [{name: data, mountPath: /data}]
          volumes: [{name: data, persistentVolumeClaim: {claimName: vw-data}}]
Y
cat > $A/middlewares.yaml <<'Y'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: lan-only, namespace: vaultwarden}
spec:
  ipAllowList:
    sourceRange: ["192.168.1.0/24", "100.64.0.0/10", "127.0.0.1/32", "10.8.0.0/24"]
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: ratelimit, namespace: vaultwarden}
spec:
  rateLimit: {average: 20, period: 1s, burst: 40}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: headers, namespace: vaultwarden}
spec:
  headers: {stsSeconds: 31536000, forceSTSHeader: true, contentTypeNosniff: true, frameDeny: true, referrerPolicy: same-origin}
Y
cat > $A/ingress.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vaultwarden
  namespace: vaultwarden
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: vaultwarden-lan-only@kubernetescrd,vaultwarden-ratelimit@kubernetescrd,vaultwarden-headers@kubernetescrd
spec:
  ingressClassName: traefik
  tls: [{hosts: [vaultwarden.lyxar.dedyn.io], secretName: vaultwarden-tls}]
  rules:
    - host: vaultwarden.lyxar.dedyn.io
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: vaultwarden, port: {number: 8080}}}}
Y
cat > $A/networkpolicy.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress, namespace: vaultwarden}
spec: {podSelector: {}, policyTypes: [Ingress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: traefik-to-vaultwarden, namespace: vaultwarden}
spec:
  podSelector: {matchLabels: {app: vaultwarden}}
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
      ports: [{port: 8080}]
Y
ok "manifiestos escritos"

echo "== 3) Velero, fugas, dry-run, push =="
python3 - <<'PY' || { echo "  ❌ falló la edición de Velero"; exit 1; }
import os,yaml
p=os.path.expanduser('~/homelab/platform/velero/velero.yaml'); docs=[d for d in yaml.safe_load_all(open(p)) if d]
for d in docs:
    if d.get('kind')=='Schedule':
        ns=d['spec']['template']['includedNamespaces']
        if 'vaultwarden' not in ns: ns.append('vaultwarden')
yaml.safe_dump_all(docs,open(p,'w'),sort_keys=False)
PY
[ -n "$TOKEN" ] && grep -rqF --exclude-dir=.git -- "$TOKEN" . && { bad "el token aparece en claro en el repo"; exit 1; }
ok "sin secretos en claro"
kubectl create ns vaultwarden --dry-run=client -o yaml | kubectl apply -f - >/dev/null; kubectl apply --dry-run=server -f $A/ >/tmp/dry11.txt 2>&1 && ok "manifiestos válidos" || { head -12 /tmp/dry11.txt; bad "dry-run falló, no se publica"; exit 1; }
git add -A; git diff --cached --quiet || git commit -qm "vaultwarden: despliegue (solo LAN/VPN), backup sqlite, velero"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh

echo "== 4) Esperando (máx 6 min) =="
for i in $(seq 1 36); do kubectl -n vaultwarden get deploy vaultwarden >/dev/null 2>&1 && break; refresh; sleep 10; done
kubectl -n vaultwarden rollout status deploy/vaultwarden --timeout=300s >/dev/null 2>&1 && ok "vaultwarden Ready" || { bad "no Ready"; kubectl -n vaultwarden get pods; kubectl -n vaultwarden logs deploy/vaultwarden --tail=15 2>&1; exit 1; }
for i in $(seq 1 30); do [ "$(kubectl -n vaultwarden get certificate vaultwarden-tls -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && break; sleep 10; done
[ "$(kubectl -n vaultwarden get certificate vaultwarden-tls -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && ok "certificado emitido" || bad "certificado pendiente"
echo "   desde el servidor (403 = filtro LAN activo, esperado): $(curl -s -o /dev/null -m 10 --resolve $HOST:443:192.168.1.47 -w '%{http_code}' https://$HOST/)"
echo "   dentro del pod /alive: $(kubectl -n vaultwarden exec deploy/vaultwarden -- sh -c 'wget -qO- http://localhost:8080/alive' 2>&1 | head -c 80)"
kubectl -n argocd get applications.argoproj.io app-vaultwarden --no-headers
echo; echo ">>> Agregá $HOST a la línea del hosts de tu PC (192.168.1.47) o usá la VPN, y creá tu cuenta en https://$HOST"
