#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
WGD=~/homelab-backup/wireguard; ENDPOINT=lyxar.dedyn.io; PORT=51820; LAB=192.168.1.47
CLIENTS="celular:2 windows:3 linux:4"
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }

echo "== 1) Paquetes =="
sudo apt-get install -y wireguard-tools qrencode >/dev/null 2>&1 && ok "wireguard-tools y qrencode" || { bad "falló apt install"; exit 1; }
sudo modprobe wireguard 2>/dev/null && ok "módulo wireguard del kernel" || { bad "el kernel no tiene wireguard"; exit 1; }

echo "== 2) Claves =="
mkdir -p "$WGD"; chmod 700 "$WGD" ~/homelab-backup
umask 077
[ -s "$WGD/server.key" ] || wg genkey > "$WGD/server.key"
wg pubkey < "$WGD/server.key" > "$WGD/server.pub"
for c in $CLIENTS; do n=${c%:*}
  [ -s "$WGD/$n.key" ] || wg genkey > "$WGD/$n.key"
  wg pubkey < "$WGD/$n.key" > "$WGD/$n.pub"
  [ -s "$WGD/$n.psk" ] || wg genpsk > "$WGD/$n.psk"
done
ok "claves en $WGD"

echo "== 3) Servidor wg0 =="
{
echo "[Interface]"; echo "Address = 10.8.0.1/24"; echo "ListenPort = $PORT"; echo "PrivateKey = $(cat $WGD/server.key)"
for c in $CLIENTS; do n=${c%:*}; ip=${c#*:}
  echo; echo "# $n"; echo "[Peer]"; echo "PublicKey = $(cat $WGD/$n.pub)"; echo "PresharedKey = $(cat $WGD/$n.psk)"; echo "AllowedIPs = 10.8.0.$ip/32"
done
} | sudo tee /etc/wireguard/wg0.conf >/dev/null
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable wg-quick@wg0 >/dev/null 2>&1
sudo systemctl restart wg-quick@wg0 && ok "wg0 activo" || { bad "wg0 no arrancó"; sudo journalctl -u wg-quick@wg0 -n 10 --no-pager; exit 1; }
sudo ss -ulnp | grep -q ":$PORT " && ok "escuchando en UDP $PORT" || bad "nada escucha en UDP $PORT"

echo "== 4) DNS dividido (dnsmasq solo en 10.8.0.1) =="
sudo mkdir -p /etc/dnsmasq.d
sudo tee /etc/dnsmasq.d/lab-vpn.conf >/dev/null <<DNS
bind-interfaces
listen-address=10.8.0.1
no-resolv
server=1.1.1.1
server=9.9.9.9
address=/lyxar.dedyn.io/$LAB
DNS
sudo apt-get install -y dnsmasq >/dev/null 2>&1 || true
sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
printf '[Unit]\nAfter=wg-quick@wg0.service\nRequires=wg-quick@wg0.service\n' | sudo tee /etc/systemd/system/dnsmasq.service.d/wg.conf >/dev/null
sudo systemctl daemon-reload; sudo systemctl enable dnsmasq >/dev/null 2>&1; sudo systemctl restart dnsmasq
sleep 2
systemctl is-active dnsmasq >/dev/null && ok "dnsmasq activo" || { bad "dnsmasq no arrancó"; sudo journalctl -u dnsmasq -n 10 --no-pager; }
R=$(dig +short @10.8.0.1 argocd.lyxar.dedyn.io | head -1); [ "$R" = "$LAB" ] && ok "argocd.lyxar.dedyn.io -> $R por la VPN" || bad "DNS devolvió '$R'"
R=$(dig +short @10.8.0.1 debian.org | head -1); [ -n "$R" ] && ok "resolución externa OK" || bad "resolución externa falla"

echo "== 5) Configuraciones de cliente =="
for c in $CLIENTS; do n=${c%:*}; ip=${c#*:}
cat > "$WGD/$n.conf" <<CONF
[Interface]
PrivateKey = $(cat $WGD/$n.key)
Address = 10.8.0.$ip/32
DNS = 10.8.0.1

[Peer]
PublicKey = $(cat $WGD/server.pub)
PresharedKey = $(cat $WGD/$n.psk)
Endpoint = $ENDPOINT:$PORT
AllowedIPs = 10.8.0.0/24, $LAB/32
PersistentKeepalive = 25
CONF
chmod 600 "$WGD/$n.conf"; ok "$WGD/$n.conf"
done

echo "== 6) Traefik: permitir 10.8.0.0/24 (por Git) =="
python3 - <<'PY'
import glob,yaml,os
os.chdir(os.path.expanduser('~/homelab'))
for f in glob.glob('apps/*/middleware-lan-only.yaml')+glob.glob('platform/*/middleware-lan-only.yaml'):
    o=yaml.safe_load(open(f)); r=o['spec']['ipAllowList']['sourceRange']
    if '10.8.0.0/24' not in r: r.append('10.8.0.0/24'); open(f,'w').write(yaml.safe_dump(o,sort_keys=False)); print('  actualizado',f)
PY
mkdir -p docs
cat > docs/VPN.md <<'MD'
# VPN (WireGuard autoalojado)
- Servidor: `wg0` 10.8.0.1/24, UDP 51820 (router: UDP 51820 -> 192.168.1.47). Endpoint: lyxar.dedyn.io.
- Clientes: celular 10.8.0.2, windows 10.8.0.3, linux 10.8.0.4. Solo enrutan 10.8.0.0/24 y 192.168.1.47.
- DNS: dnsmasq en 10.8.0.1 resuelve *.lyxar.dedyn.io a 192.168.1.47.
- Claves y configs: ~/homelab-backup/wireguard (NO en Git; copiar fuera del servidor).
- Se reconstruye con `scripts/phase7a-wireguard.sh` (reutiliza las claves si existen).
MD
git add -A; git diff --cached --quiet || git commit -qm "vpn: wireguard, permitir 10.8.0.0/24 en lan-only, docs"
git push -q && ok "push OK" || bad "push falló"
refresh; sleep 45
kubectl -n argocd get applications.argoproj.io --no-headers
kubectl -n argocd get middleware lan-only -o jsonpath='{.spec.ipAllowList.sourceRange}{"\n"}' 2>/dev/null
kubectl -n monitoring get middleware lan-only -o jsonpath='  monitoring: {.spec.ipAllowList.sourceRange}{"\n"}'

echo; echo "== QR para el celular (contiene la clave privada: no lo compartas) =="
qrencode -t ansiutf8 < "$WGD/celular.conf"
echo; sudo wg show wg0 | grep -E 'interface|listening|peer' 
