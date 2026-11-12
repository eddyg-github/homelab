#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
CN=sealed-secrets-controller; CNS=kube-system; GK=~/homelab-backup/guacamole; A=apps/guacamole
GUSER=edu
rand(){ head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
refresh(){ kubectl -n argocd annotate applicationset apps argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1
  for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }

echo "== 0) Pre-chequeos =="
command -v kubeseal >/dev/null && ok kubeseal || { bad "falta kubeseal"; exit 1; }
kubectl -n $CNS get deploy $CN >/dev/null 2>&1 && ok "Sealed Secrets" || { bad "falta Sealed Secrets"; exit 1; }
[ -s sealed-secrets-pub.crt ] || kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt
kubectl get applicationset apps -n argocd >/dev/null 2>&1 && ok "ApplicationSet apps" || { bad "falta el ApplicationSet apps"; exit 1; }

echo "== 1) xrdp + LXQt en el host =="
sudo apt-get install -y xrdp xorgxrdp >/dev/null 2>&1 && ok "xrdp y xorgxrdp instalados" || { bad "falló apt install"; exit 1; }
sudo adduser xrdp ssl-cert >/dev/null 2>&1
printf 'startlxqt\n' > ~/.xsession; chmod 755 ~/.xsession
sudo systemctl enable xrdp >/dev/null 2>&1; sudo systemctl restart xrdp
sleep 3
sudo ss -tlnp | grep -q ':3389 ' && ok "xrdp escucha en 3389" || { bad "xrdp no escucha"; sudo journalctl -u xrdp -n 10 --no-pager; exit 1; }

echo "== 2) Clave SSH dedicada para Guacamole =="
mkdir -p $GK; chmod 700 $GK
[ -s $GK/ssh_key ] || ssh-keygen -t ed25519 -N "" -C guacamole@sparky -f $GK/ssh_key -q
PUB=$(cut -d' ' -f1,2 $GK/ssh_key.pub)
grep -qF "$PUB" ~/.ssh/authorized_keys 2>/dev/null || echo "from=\"10.42.0.0/16\" $(cat $GK/ssh_key.pub)" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys $GK/ssh_key; ok "clave en $GK y autorizada (solo desde la red de pods)"

echo "== 3) Secret de la base de datos (cifrado) =="
mkdir -p $A docs
kubectl apply -f - >/dev/null <<'Y'
apiVersion: v1
kind: Namespace
metadata: {name: guacamole}
Y
if kubectl -n guacamole get secret guac-db >/dev/null 2>&1 && [ -s $A/sealedsecret-guac-db.yaml ]; then
  DBPASS=$(kubectl -n guacamole get secret guac-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d); ok "reutilizo el secret existente"
else
  DBPASS=$(rand)
  jq -n --arg p "$DBPASS" '{apiVersion:"v1",kind:"Secret",metadata:{name:"guac-db",namespace:"guacamole"},type:"Opaque",data:{POSTGRES_USER:("guacamole"|@base64),POSTGRES_PASSWORD:($p|@base64),POSTGRES_DB:("guacamole_db"|@base64)}}' \
   | kubeseal --cert sealed-secrets-pub.crt --format yaml > $A/sealedsecret-guac-db.yaml && [ -s $A/sealedsecret-guac-db.yaml ] && ok "SealedSecret generado" || { bad "no pude cifrar"; exit 1; }
fi

echo "== 4) Manifiestos =="
cat > $A/namespace.yaml <<'Y'
apiVersion: v1
kind: Namespace
metadata: {name: guacamole}
Y
cat > $A/postgres.yaml <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: guac-pgdata, namespace: guacamole}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 2Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: postgres, namespace: guacamole}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: guac-postgres}}
  template:
    metadata: {labels: {app: guac-postgres}}
    spec:
      securityContext: {fsGroup: 70, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: postgres
          image: postgres:16-alpine
          securityContext: {runAsUser: 70, runAsNonRoot: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          ports: [{containerPort: 5432}]
          env:
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
            - {name: POSTGRES_USER, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_USER}}}
            - {name: POSTGRES_PASSWORD, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_PASSWORD}}}
            - {name: POSTGRES_DB, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_DB}}}
          readinessProbe: {exec: {command: [sh, -c, 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"']}, periodSeconds: 10, failureThreshold: 12}
          resources: {requests: {cpu: 20m, memory: 128Mi}, limits: {memory: 384Mi}}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
      volumes: [{name: data, persistentVolumeClaim: {claimName: guac-pgdata}}]
---
apiVersion: v1
kind: Service
metadata: {name: postgres, namespace: guacamole}
spec: {selector: {app: guac-postgres}, ports: [{name: pg, port: 5432, targetPort: 5432}]}
Y
cat > $A/guacd.yaml <<'Y'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: guacd
  namespace: guacamole
  annotations: {argocd.argoproj.io/sync-wave: "2"}
spec:
  replicas: 1
  selector: {matchLabels: {app: guacd}}
  template:
    metadata: {labels: {app: guacd}}
    spec:
      securityContext: {seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: guacd
          image: guacamole/guacd:1.5.5
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          ports: [{containerPort: 4822}]
          resources: {requests: {cpu: 20m, memory: 64Mi}, limits: {memory: 256Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: guacd, namespace: guacamole, annotations: {argocd.argoproj.io/sync-wave: "2"}}
spec: {selector: {app: guacd}, ports: [{name: guacd, port: 4822, targetPort: 4822}]}
Y
cat > $A/guacamole.yaml <<'Y'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: guacamole
  namespace: guacamole
  annotations: {argocd.argoproj.io/sync-wave: "2"}
spec:
  replicas: 1
  selector: {matchLabels: {app: guacamole}}
  template:
    metadata: {labels: {app: guacamole}}
    spec:
      securityContext: {seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: guacamole
          image: guacamole/guacamole:1.5.5
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          ports: [{containerPort: 8080}]
          env:
            - {name: GUACD_HOSTNAME, value: guacd}
            - {name: GUACD_PORT, value: "4822"}
            - {name: POSTGRESQL_HOSTNAME, value: postgres}
            - {name: POSTGRESQL_DATABASE, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_DB}}}
            - {name: POSTGRESQL_USER, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_USER}}}
            - {name: POSTGRESQL_PASSWORD, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_PASSWORD}}}
            - {name: WEBAPP_CONTEXT, value: ROOT}
            - {name: TOTP_ENABLED, value: "true"}
            - {name: TOTP_ISSUER, value: Sparky Lab}
            - {name: BAN_ENABLED, value: "true"}
            - {name: BAN_MAX_INVALID_ATTEMPTS, value: "5"}
            - {name: BAN_ADDRESS_DURATION, value: "900"}
            - {name: REMOTE_IP_VALVE_ENABLED, value: "true"}
            - {name: PROXY_ALLOWED_IPS_REGEX, value: '10\.42\.\d+\.\d+|127\.0\.0\.1|::1'}
          readinessProbe: {httpGet: {path: /, port: 8080}, initialDelaySeconds: 40, periodSeconds: 10, failureThreshold: 18}
          resources: {requests: {cpu: 50m, memory: 384Mi}, limits: {memory: 768Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: guacamole, namespace: guacamole, annotations: {argocd.argoproj.io/sync-wave: "2"}}
spec: {selector: {app: guacamole}, ports: [{name: http, port: 8080, targetPort: 8080}]}
Y
cat > $A/dbtools.yaml <<'Y'
apiVersion: batch/v1
kind: Job
metadata:
  name: guac-db-init
  namespace: guacamole
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "1"
spec:
  backoffLimit: 6
  template:
    metadata: {labels: {app: guac-dbtools}}
    spec:
      restartPolicy: OnFailure
      initContainers:
        - name: gen-schema
          image: guacamole/guacamole:1.5.5
          command: [/bin/sh, -c, "/opt/guacamole/bin/initdb.sh --postgresql > /sql/initdb.sql"]
          volumeMounts: [{name: sql, mountPath: /sql}]
      containers:
        - name: init
          image: postgres:16-alpine
          env:
            - {name: PGHOST, value: postgres}
            - {name: PGUSER, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_USER}}}
            - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_PASSWORD}}}
            - {name: PGDATABASE, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_DB}}}
          command: [/bin/sh, -c]
          args:
            - |
              until pg_isready -q; do sleep 2; done
              if psql -tAc "select to_regclass('public.guacamole_user')" | grep -q guacamole_user; then
                echo "esquema ya existe"
              else
                psql -v ON_ERROR_STOP=1 -f /sql/initdb.sql
              fi
          volumeMounts: [{name: sql, mountPath: /sql}]
      volumes: [{name: sql, emptyDir: {}}]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: guac-dumps, namespace: guacamole}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 1Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: guac-dumps-holder, namespace: guacamole}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: guac-dumps-holder}}
  template:
    metadata:
      labels: {app: guac-dumps-holder}
      annotations: {backup.velero.io/backup-volumes: dumps}
    spec:
      containers:
        - name: holder
          image: busybox:1.36
          command: [sh, -c, "while true; do sleep 3600; done"]
          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {memory: 32Mi}}
          volumeMounts: [{name: dumps, mountPath: /dumps}]
      volumes: [{name: dumps, persistentVolumeClaim: {claimName: guac-dumps}}]
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: guac-pgdump, namespace: guacamole}
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata: {labels: {app: guac-dbtools}}
        spec:
          restartPolicy: OnFailure
          containers:
            - name: dump
              image: postgres:16-alpine
              env:
                - {name: PGHOST, value: postgres}
                - {name: PGUSER, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_USER}}}
                - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_PASSWORD}}}
                - {name: PGDATABASE, valueFrom: {secretKeyRef: {name: guac-db, key: POSTGRES_DB}}}
              command: [/bin/sh, -c]
              args:
                - |
                  set -e
                  F=/dumps/guac-$(date +%F).sql
                  pg_dump > "$F"
                  gzip -f "$F"
                  find /dumps -name 'guac-*.sql.gz' -mtime +7 -delete
                  ls -la /dumps
              resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
              volumeMounts: [{name: dumps, mountPath: /dumps}]
          volumes: [{name: dumps, persistentVolumeClaim: {claimName: guac-dumps}}]
Y
cat > $A/middlewares.yaml <<'Y'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: lan-only, namespace: guacamole}
spec:
  ipAllowList:
    sourceRange: ["192.168.1.0/24", "100.64.0.0/10", "127.0.0.1/32", "10.8.0.0/24"]
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: ratelimit, namespace: guacamole}
spec:
  rateLimit: {average: 30, period: 1s, burst: 60}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: headers, namespace: guacamole}
spec:
  headers:
    stsSeconds: 31536000
    forceSTSHeader: true
    contentTypeNosniff: true
    frameDeny: true
    referrerPolicy: same-origin
Y
cat > $A/ingress.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: guacamole
  namespace: guacamole
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: guacamole-lan-only@kubernetescrd,guacamole-ratelimit@kubernetescrd,guacamole-headers@kubernetescrd
    argocd.argoproj.io/sync-wave: "2"
spec:
  ingressClassName: traefik
  tls: [{hosts: [guacamole.lyxar.dedyn.io], secretName: guacamole-tls}]
  rules:
    - host: guacamole.lyxar.dedyn.io
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: guacamole, port: {number: 8080}}}}
Y
cat > $A/networkpolicy.yaml <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress, namespace: guacamole}
spec: {podSelector: {}, policyTypes: [Ingress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: traefik-to-guacamole, namespace: guacamole}
spec:
  podSelector: {matchLabels: {app: guacamole}}
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
      ports: [{port: 8080}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: guacamole-to-guacd, namespace: guacamole}
spec:
  podSelector: {matchLabels: {app: guacd}}
  ingress:
    - from: [{podSelector: {matchLabels: {app: guacamole}}}]
      ports: [{port: 4822}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: to-postgres, namespace: guacamole}
spec:
  podSelector: {matchLabels: {app: guac-postgres}}
  ingress:
    - from:
        - podSelector: {matchExpressions: [{key: app, operator: In, values: [guacamole, guac-dbtools]}]}
      ports: [{port: 5432}]
Y
ok "manifiestos escritos en $A"

echo "== 5) Chequeo de fugas, dry-run, Velero y reglas de alerta =="
grep -rqF --exclude-dir=.git -- "$DBPASS" . && { bad "la contraseña de la base aparece en claro en el repo"; exit 1; }
grep -rq --exclude-dir=.git --exclude-dir=scripts 'BEGIN OPENSSH PRIVATE KEY' . && { bad "hay una clave privada en el repo"; exit 1; }
ok "sin secretos en claro"
kubectl apply --dry-run=server -f $A/ >/tmp/dry8.txt 2>&1 && ok "manifiestos válidos para el cluster" || { head -15 /tmp/dry8.txt; bad "dry-run falló, no se publica"; exit 1; }
python3 - <<'PY' || { echo "  ❌ falló la edición de Velero o alertas"; exit 1; }
import os,yaml,hashlib
H=os.path.expanduser('~/homelab/')
p=H+'platform/velero/velero.yaml'; docs=[d for d in yaml.safe_load_all(open(p)) if d]
for d in docs:
    if d.get('kind')=='Schedule':
        ns=d['spec']['template']['includedNamespaces']
        if 'guacamole' not in ns: ns.append('guacamole')
yaml.safe_dump_all(docs,open(p,'w'),sort_keys=False)
class L(str): pass
yaml.add_representer(L,lambda d,s:d.represent_scalar('tag:yaml.org,2002:str',s,style='|'),Dumper=yaml.SafeDumper)
D=H+'apps/monitoring/'
R=lambda a,e,f,sev,s:{'alert':a,'expr':e,'for':f,'labels':{'severity':sev},'annotations':{'summary':s}}
f=D+'configmap-vmalert-rules.yaml'; cm=yaml.safe_load(open(f)); rules=yaml.safe_load(cm['data']['rules.yaml'])
if not any(g['name']=='guacamole' for g in rules['groups']):
    rules['groups'].append({'name':'guacamole','interval':'60s','rules':[
      R('GuacamoleLoginFailures','sum(increase(traefik_service_requests_total{service=~".*guacamole.*",code="403"}[10m])) > 10','0m','warning','Muchos intentos fallidos de login en Guacamole en 10 minutos (posible fuerza bruta)'),
      R('GuacamoleDumpStale','time() - kube_cronjob_status_last_successful_time{cronjob="guac-pgdump"} > 129600','1h','warning','El pg_dump de Guacamole no termina con exito hace mas de 36 horas')]})
txt=yaml.safe_dump(rules,sort_keys=False,width=200,allow_unicode=True)
cm['data']['rules.yaml']=L(txt); open(f,'w').write(yaml.safe_dump(cm,sort_keys=False,width=200,allow_unicode=True))
f=D+'deployment-vmalert.yaml'; o=yaml.safe_load(open(f))
o['spec']['template'].setdefault('metadata',{}).setdefault('annotations',{})['checksum/rules']=hashlib.sha256(txt.encode()).hexdigest()[:12]
open(f,'w').write(yaml.safe_dump(o,sort_keys=False,width=200))
PY
cat > docs/GUACAMOLE.md <<'MD'
# Guacamole (acceso remoto web)
- k3s, namespace `guacamole`: guacamole + guacd + postgres. URL: https://guacamole.lyxar.dedyn.io
- Protecciones: 2FA TOTP, bloqueo por intentos (5 fallos, 15 min), rate limit y cabeceras en Traefik, NetworkPolicies, usuario sin root (sudo con contraseña).
- Conexiones: SSH (clave dedicada ~/homelab-backup/guacamole/ssh_key, autorizada solo desde 10.42.0.0/16) y RDP a xrdp (LXQt, ~/.xsession). La contraseña del escritorio se pide en cada conexión.
- Backup: CronJob guac-pgdump (diario) escribe en el volumen guac-dumps, que Velero respalda. Los datos vivos de Postgres NO se respaldan.
- Restaurar: velero restore del namespace guacamole; luego `gunzip -c guac-FECHA.sql.gz | kubectl -n guacamole exec -i deploy/postgres -- psql -U guacamole guacamole_db`.
- Usuarios y conexiones viven en la base (no en Git). En un cluster nuevo: restaurar el dump.
- xrdp y su ~/.xsession viven en el host: recrear con scripts/phase8a-guacamole.sh.
MD
git add -A; git diff --cached --quiet || git commit -qm "guacamole: stack en k3s (solo LAN/VPN), netpol, pg_dump, velero, alertas"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh

echo "== 6) Esperando el despliegue (máx 10 min) =="
for i in $(seq 1 60); do kubectl -n guacamole get deploy postgres guacd guacamole >/dev/null 2>&1 && break; refresh; sleep 10; done
kubectl -n guacamole rollout status deploy/postgres --timeout=300s >/dev/null 2>&1 && ok "postgres Ready" || { bad "postgres no Ready"; kubectl -n guacamole get pods; exit 1; }
for i in $(seq 1 60); do [ "$(kubectl -n guacamole get job guac-db-init -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ] && break; sleep 10; done
[ "$(kubectl -n guacamole get job guac-db-init -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ] && ok "esquema de la base creado" || { bad "el job de init no terminó"; kubectl -n guacamole logs job/guac-db-init --all-containers --tail=15 2>&1; exit 1; }
for d in guacd guacamole; do kubectl -n guacamole rollout status deploy/$d --timeout=420s >/dev/null 2>&1 && ok "$d Ready" || { bad "$d no Ready"; kubectl -n guacamole logs deploy/$d --tail=15 2>&1; exit 1; }; done

echo "== 7) Extensiones de seguridad cargadas =="
EXT=$(kubectl -n guacamole exec deploy/guacamole -- ls /etc/guacamole/extensions 2>&1)
echo "$EXT" | sed 's/^/   /'
echo "$EXT" | grep -qi totp && ok "2FA (TOTP) cargado" || { bad "TOTP NO está cargado. No sigas: avisame."; exit 1; }
echo "$EXT" | grep -qi ban && ok "bloqueo por intentos cargado" || { bad "extensión de bloqueo NO cargada. No sigas: avisame."; exit 1; }

echo "== 8) ¿Llegan los pods a SSH y xrdp del host? =="
kubectl -n default delete pod nettest --ignore-not-found >/dev/null 2>&1
kubectl run nettest -n default --rm -i --restart=Never --image=busybox:1.36 --command -- sh -c 'nc -zv -w4 192.168.1.47 22; nc -zv -w4 192.168.1.47 3389' 2>&1 | grep -E 'open|succeeded|refused|timed|failed' | sed 's/^/   /'

echo "== 9) Usuario $GUSER y conexiones (contraseña por terminal) =="
if [ "$(kubectl -n guacamole exec deploy/postgres -- psql -U guacamole -d guacamole_db -tAc "select count(*) from guacamole_entity where name='$GUSER' and type='USER'")" = 1 ]; then
  ok "el usuario $GUSER ya existe: no lo toco"
else
  read -rsp "   Elegí la contraseña de '$GUSER' en Guacamole (mínimo 14 caracteres): " P1; echo
  read -rsp "   Repetila: " P2; echo
  [ "$P1" = "$P2" ] && [ ${#P1} -ge 14 ] || { bad "no coinciden o es corta"; exit 1; }
  SALT=$(GPW="$P1" python3 -c 'import os,hashlib;s=os.urandom(32).hex().upper();print(s,hashlib.sha256((os.environ["GPW"]+s).encode()).hexdigest().upper())')
  SH=${SALT% *}; HH=${SALT#* }; unset P1 P2 SALT
  kubectl -n guacamole exec -i deploy/postgres -- psql -U guacamole -d guacamole_db -v ON_ERROR_STOP=1 \
    -v uname="$GUSER" -v salt="$SH" -v hash="$HH" -v sshuser="$USER" -v "key=$(cat $GK/ssh_key)" -f - >/tmp/seed.txt 2>&1 <<'SQL'
BEGIN;
INSERT INTO guacamole_entity (name,type) VALUES (:'uname','USER') ON CONFLICT DO NOTHING;
INSERT INTO guacamole_user (entity_id,password_salt,password_hash,password_date)
  SELECT entity_id, decode(:'salt','hex'), decode(:'hash','hex'), CURRENT_TIMESTAMP FROM guacamole_entity
  WHERE name=:'uname' AND type='USER' AND entity_id NOT IN (SELECT entity_id FROM guacamole_user);
INSERT INTO guacamole_system_permission (entity_id,permission)
  SELECT e.entity_id, p::guacamole_system_permission_type FROM guacamole_entity e,
  unnest(ARRAY['CREATE_CONNECTION','CREATE_CONNECTION_GROUP','CREATE_SHARING_PROFILE','CREATE_USER','CREATE_USER_GROUP','ADMINISTER']) p
  WHERE e.name=:'uname' AND e.type='USER' ON CONFLICT DO NOTHING;
INSERT INTO guacamole_connection (connection_name,protocol) SELECT 'Sparky SSH','ssh' WHERE NOT EXISTS (SELECT 1 FROM guacamole_connection WHERE connection_name='Sparky SSH');
INSERT INTO guacamole_connection (connection_name,protocol) SELECT 'Sparky Escritorio','rdp' WHERE NOT EXISTS (SELECT 1 FROM guacamole_connection WHERE connection_name='Sparky Escritorio');
INSERT INTO guacamole_connection_parameter (connection_id,parameter_name,parameter_value)
  SELECT c.connection_id, v.n, v.v FROM guacamole_connection c, (VALUES ('hostname','192.168.1.47'),('port','22'),('username',:'sshuser'),('private-key',:'key')) AS v(n,v)
  WHERE c.connection_name='Sparky SSH' ON CONFLICT DO NOTHING;
INSERT INTO guacamole_connection_parameter (connection_id,parameter_name,parameter_value)
  SELECT c.connection_id, v.n, v.v FROM guacamole_connection c, (VALUES ('hostname','192.168.1.47'),('port','3389'),('security','any'),('ignore-cert','true'),('resize-method','display-update'),('enable-wallpaper','false')) AS v(n,v)
  WHERE c.connection_name='Sparky Escritorio' ON CONFLICT DO NOTHING;
INSERT INTO guacamole_connection_permission (entity_id,connection_id,permission)
  SELECT e.entity_id, c.connection_id, 'READ' FROM guacamole_entity e, guacamole_connection c
  WHERE e.name=:'uname' AND e.type='USER' AND c.connection_name IN ('Sparky SSH','Sparky Escritorio') ON CONFLICT DO NOTHING;
DELETE FROM guacamole_entity WHERE name='guacadmin' AND type='USER';
COMMIT;
SQL
  [ $? = 0 ] && ok "usuario, permisos y conexiones creados; guacadmin eliminado" || { bad "falló el seed:"; sed 's/private-key.*/private-key ***/' /tmp/seed.txt | tail -8; exit 1; }
  rm -f /tmp/seed.txt
fi
echo "   guacadmin existe: $(kubectl -n guacamole exec deploy/postgres -- psql -U guacamole -d guacamole_db -tAc "select count(*) from guacamole_entity where name='guacadmin'")  (debe ser 0)"
echo "   conexiones: $(kubectl -n guacamole exec deploy/postgres -- psql -U guacamole -d guacamole_db -tAc "select string_agg(connection_name,', ') from guacamole_connection")"

echo "== 10) Certificado =="
for i in $(seq 1 30); do [ "$(kubectl -n guacamole get certificate guacamole-tls -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && break; sleep 10; done
[ "$(kubectl -n guacamole get certificate guacamole-tls -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && ok "certificado emitido" || bad "certificado pendiente (puede tardar unos minutos)"
echo "   respuesta desde el servidor (403 = filtro de LAN activo, esperado): $(curl -s -o /dev/null -m 10 --resolve guacamole.lyxar.dedyn.io:443:192.168.1.47 -w '%{http_code}' https://guacamole.lyxar.dedyn.io/)"
kubectl -n argocd get applications.argoproj.io app-guacamole 2>&1 | tail -2
echo; echo ">>> Siguiente: configurar el 2FA desde tu PC (ver instrucciones en el chat)."
