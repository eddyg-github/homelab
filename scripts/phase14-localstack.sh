#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
A=apps/localstack; HOST=localstack.lyxar.dedyn.io
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
  kubectl -n argocd annotate applicationset apps argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1; }
mkdir -p $A

echo "== 1) Backup diario a /mnt/media4 =="
sudo mkdir -p /mnt/media4/backups/localstack
sudo tee /usr/local/bin/localstack-backup >/dev/null <<'B'
#!/bin/bash
set -e
D=/mnt/media4/backups/localstack
tar czf "$D/localstack-$(date +%F).tgz" --exclude='s5cmd.tar.gz' -C /home/user/lab localstack
find "$D" -name 'localstack-*.tgz' -mtime +14 -delete
B
sudo chmod 755 /usr/local/bin/localstack-backup
sudo tee /etc/systemd/system/lab-localstack-backup.service >/dev/null <<'U'
[Unit]
Description=Lab: backup de la carpeta de LocalStack
[Service]
Type=oneshot
ExecStart=/usr/local/bin/localstack-backup
Nice=10
IOSchedulingClass=idle
U
sudo tee /etc/systemd/system/lab-localstack-backup.timer >/dev/null <<'U'
[Unit]
Description=Lab: backup de LocalStack diario 04:00
[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
[Install]
WantedBy=timers.target
U
sudo systemctl daemon-reload && sudo systemctl enable --now lab-localstack-backup.timer >/dev/null 2>&1 && ok "timer activo"
sudo systemctl start lab-localstack-backup.service && ok "primer backup hecho" || bad "el backup falló"
ls -la /mnt/media4/backups/localstack | tail -3

echo "== 2) Ingress =="
cat > $A/namespace.yaml <<'Y'
apiVersion: v1
kind: Namespace
metadata: {name: localstack}
Y
cat > $A/localstack.yaml <<'Y'
apiVersion: v1
kind: Service
metadata: {name: localstack, namespace: localstack}
spec: {ports: [{name: http, port: 4566, targetPort: 4566}]}
---
apiVersion: v1
kind: Endpoints
metadata: {name: localstack, namespace: localstack}
subsets: [{addresses: [{ip: 192.168.1.47}], ports: [{name: http, port: 4566}]}]
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: lan-only, namespace: localstack}
spec:
  ipAllowList:
    sourceRange: ["192.168.1.0/24", "100.64.0.0/10", "127.0.0.1/32", "10.8.0.0/24"]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: localstack
  namespace: localstack
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: localstack-lan-only@kubernetescrd
spec:
  ingressClassName: traefik
  tls: [{hosts: [localstack.lyxar.dedyn.io], secretName: localstack-tls}]
  rules:
    - host: localstack.lyxar.dedyn.io
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: localstack, port: {number: 4566}}}}
Y
kubectl create ns localstack --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply --dry-run=server -f $A/ >/tmp/dry14.txt 2>&1 && ok "manifiestos válidos" || { head -10 /tmp/dry14.txt; bad "dry-run falló"; exit 1; }
cat >> docs/HOST.md <<'M'
- **LocalStack (Docker, ~/lab/localstack):** Ingress en `apps/localstack/` (Service+Endpoints a 192.168.1.47:4566). Backup diario: `lab-localstack-backup.timer` -> `/mnt/media4/backups/localstack` (14 días). Se recrea con `scripts/phase14-localstack.sh`. Lambda no funciona en k3s (sin acceso a Docker), por eso sigue en Docker.
M
git add -A; git diff --cached --quiet || git commit -qm "localstack: ingress https (LAN/VPN) y backup diario"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh
for i in $(seq 1 36); do [ "$(kubectl -n localstack get certificate localstack-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break; sleep 10; done
[ "$(kubectl -n localstack get certificate localstack-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && ok "certificado emitido" || { bad "certificado pendiente. NO borres nada. Motivo:"; kubectl -n localstack describe challenge 2>/dev/null | grep -E 'Reason' | head -2 | cut -c1-250; }
echo "   desde el servidor (403 = filtro LAN, esperado): $(curl -s -o /dev/null -m 10 --resolve $HOST:443:192.168.1.47 -w '%{http_code}' https://$HOST/)"
kubectl -n argocd get applications.argoproj.io app-localstack --no-headers
