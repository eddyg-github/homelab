#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
LAN=192.168.1.0/24; VPN=10.8.0.0/24; PODS=10.42.0.0/16; SVC=10.43.0.0/16

echo "== 1) Estado previo y copia =="
sudo ufw version | head -1
sudo cp -a /etc/ufw ~/homelab-backup/ufw.bak-$(date +%s) && ok "copia de /etc/ufw"
sudo cp /etc/default/ufw ~/homelab-backup/default-ufw.bak-$(date +%s)
sudo ufw status | head -2
kubectl get nodes --no-headers | awk '{print "   nodo:",$2}'

echo "== 2) Reglas =="
sudo ufw --force reset >/dev/null
sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw default deny incoming >/dev/null
sudo ufw default allow outgoing >/dev/null
sudo ufw allow in on lo >/dev/null
sudo ufw allow in on cni0 >/dev/null
sudo ufw allow in on flannel.1 >/dev/null
sudo ufw allow from $PODS >/dev/null
sudo ufw allow from $SVC >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo ufw allow 51820/udp >/dev/null
for n in $LAN $VPN; do
  sudo ufw allow from $n to any port 22 proto tcp >/dev/null
  sudo ufw allow from $n to any port 6443 proto tcp >/dev/null
  sudo ufw allow from $n to any port 10250 proto tcp >/dev/null
  sudo ufw allow from $n to any port 9101 proto tcp >/dev/null
  sudo ufw allow from $n to any port 4566 proto tcp >/dev/null
done
sudo ufw allow from $VPN to any port 53 >/dev/null
ok "reglas cargadas (todavía inactivo)"

echo "== 3) Reversión automática a los 330 s =="
sudo systemctl stop ufw-rollback.timer 2>/dev/null
sudo systemd-run --unit=ufw-rollback --on-active=330 /usr/sbin/ufw disable >/dev/null && ok "ufw se desactiva solo a los 5,5 min si no confirmás"

echo "== 4) Activo =="
sudo ufw --force enable >/dev/null && ok "ufw activo"
sleep 15

echo "== 5) Pruebas automáticas =="
kubectl get nodes --no-headers | awk '{print "   nodo:",$2}'
kubectl -n argocd get pods --no-headers | awk '$3!="Running"{print "   pod no Running:",$1}'
R=$(dig +short @10.8.0.1 argocd.lyxar.dedyn.io | head -1); [ "$R" = 192.168.1.47 ] && ok "DNS de la VPN" || bad "DNS de la VPN: '$R'"
for h in jellyfin argocd grafana sonarr; do
  echo "   $h: $(curl -s -o /dev/null -m 10 --resolve $h.lyxar.dedyn.io:443:192.168.1.47 -w '%{http_code}' https://$h.lyxar.dedyn.io/)"
done
echo "   targets caídos: $(kubectl get --raw '/api/v1/namespaces/monitoring/services/victoriametrics:8428/proxy/api/v1/query?query=count(up==0)' | jq -r '.data.result[0].value[1] // 0')"

echo
echo ">>> Abrí AHORA otra sesión SSH NUEVA desde tu PC (ssh user@192.168.1.47) y verificá que entra."
echo ">>> También probá el celular por la VPN (argocd, grafana) y Jellyfin por tu dominio."
read -r -t 300 -p ">>> Si TODO anda, escribí SI y Enter (300 s): " A
if [ "${A:-}" = SI ]; then
  sudo systemctl stop ufw-rollback.timer && ok "firewall confirmado, reversión cancelada"
  sudo ufw status numbered
else
  bad "sin confirmación: el firewall se desactiva solo en pocos segundos"
fi
