# Nextcloud
- Namespace `nextcloud`: nextcloud (apache) + postgres + redis. URL: https://nextcloud.lyxar.dedyn.io (solo LAN/VPN).
- Datos de usuarios: hostPath `/mnt/media3/nextcloud` (NO en Velero; respaldar aparte). Configuración: PVC `nc-html` (Velero). Base: CronJob `nc-pgdump` -> PVC `nc-dumps` (Velero).
- Restaurar la base: `gunzip -c nextcloud-FECHA.sql.gz | kubectl -n nextcloud exec -i deploy/nc-postgres -- psql -U nextcloud nextcloud`.
- Actualizar: cambiar el tag de la imagen UNA versión mayor por vez; nunca saltar versiones mayores.
