# VPN (WireGuard autoalojado)
- Servidor: `wg0` 10.8.0.1/24, UDP 51820 (router: UDP 51820 -> 192.168.1.47). Endpoint: lyxar.dedyn.io.
- Clientes: celular 10.8.0.2, windows 10.8.0.3, linux 10.8.0.4. Solo enrutan 10.8.0.0/24 y 192.168.1.47.
- DNS: dnsmasq en 10.8.0.1 resuelve *.lyxar.dedyn.io a 192.168.1.47.
- Claves y configs: ~/homelab-backup/wireguard (NO en Git; copiar fuera del servidor).
- Se reconstruye con `scripts/phase7a-wireguard.sh` (reutiliza las claves si existen).
