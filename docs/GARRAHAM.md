# Planígrafo (planigrafo)
- Manifiestos en `apps/planigrafo/`. Imágenes privadas: `ghcr.io/eddyg-github/planigrafo-{backend,frontend}:<fecha>-N` (secret `ghcr-pull`).
- Cambiar la app: construir la imagen con tag NUEVO, subirla a GHCR, editar el tag en `apps/planigrafo/deployment-*.yaml`, git push. NO tocar el Ingress ni el Certificate (límite de Let's Encrypt: 5 por semana por dominio).
- Backup: CronJob `mysql-backup` (03:00) escribe en el PVC `mysql-backup`, que Velero respalda (holder). Los datos vivos de MariaDB no se respaldan.
