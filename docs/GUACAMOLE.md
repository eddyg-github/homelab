# Guacamole (acceso remoto web)
- k3s, namespace `guacamole`: guacamole + guacd + postgres. URL: https://guacamole.lyxar.dedyn.io
- Protecciones: 2FA TOTP, bloqueo por intentos (5 fallos, 15 min), rate limit y cabeceras en Traefik, NetworkPolicies, usuario sin root (sudo con contraseña).
- Conexiones: SSH (clave dedicada ~/homelab-backup/guacamole/ssh_key, autorizada solo desde 10.42.0.0/16) y RDP a xrdp (LXQt, ~/.xsession). La contraseña del escritorio se pide en cada conexión.
- Backup: CronJob guac-pgdump (diario) escribe en el volumen guac-dumps, que Velero respalda. Los datos vivos de Postgres NO se respaldan.
- Restaurar: velero restore del namespace guacamole; luego `gunzip -c guac-FECHA.sql.gz | kubectl -n guacamole exec -i deploy/postgres -- psql -U guacamole guacamole_db`.
- Usuarios y conexiones viven en la base (no en Git). En un cluster nuevo: restaurar el dump.
- xrdp y su ~/.xsession viven en el host: recrear con scripts/phase8a-guacamole.sh.
