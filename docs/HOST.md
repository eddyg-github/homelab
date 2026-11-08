# Métricas del host
- `/usr/local/bin/lab-host-metrics` (root, timer systemd cada 5 min) escribe `/var/lib/node_exporter/textfile/lab_host.prom`; node-exporter lo lee.
- Mide: SMART de los discos, paquetes pendientes (apt/snap/flatpak), reinicio requerido, unidades systemd fallidas, contenedores Docker y LocalStack.
- Las alertas están en el grupo `host` de `apps/monitoring/configmap-vmalert-rules.yaml`.
- El script y los units NO viven en Git de forma automática: en un servidor nuevo, volver a correr `scripts/phase6c-host.sh`.
- Actualizar a mano cuando llegue el aviso: `sudo /usr/local/bin/updn` (puede actualizar kernel/containerd; hacerlo con calma).
