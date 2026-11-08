# Backups (Velero + MinIO)
- Destino: bucket `velero` en MinIO, datos en `/mnt/media4/minio-data` (disco distinto al del sistema).
- Programación: `daily` a las 03:30, retención 14 días. Respalda `/config` de Jellyfin, Sonarr, Radarr, Prowlarr y qBittorrent (opt-in por anotación `backup.velero.io/backup-volumes`).
- No respalda: la media, la caché de Jellyfin, MinIO en sí ni los datos de VictoriaMetrics.
- Backup manual: `velero backup create manual-$(date +%F) --from-schedule daily --wait`
- Listar: `velero backup get`. Restaurar: `velero restore create --from-backup <nombre> --wait`
- Cluster nuevo: restaurar clave de Sealed Secrets, ArgoCD, apps; luego `velero restore create --from-backup <ultimo>`.
- Limitación: MinIO vive en el mismo servidor; no cubre pérdida del equipo. Copiar el bucket fuera del servidor es un paso pendiente.
