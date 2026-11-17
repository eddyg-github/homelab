# Immich
- Namespace `immich`: server (ML desactivado) + postgres (VectorChord) + valkey. https://immich.lyxar.dedyn.io (solo LAN/VPN).
- Fotos: hostPath `/mnt/media3/immich` (NO en Velero; respaldar aparte). Base: CronJob `im-pgdump` -> PVC `im-dumps` (Velero).
- Actualizar: cambiar el tag de immich-server y la imagen de postgres siguiendo las notas de la release.
