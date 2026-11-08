# Monitoreo
- **Recolección:** vmagent (`apps/monitoring/vmagent-config.yaml`) scrapea node-exporter, cAdvisor, kubelet, apiserver, MinIO y los componentes de monitoreo. OTEL Collector sigue recibiendo OTLP y scrapeando kube-state-metrics, cert-manager, ArgoCD, Traefik y pods anotados.
- **Almacenamiento:** VictoriaMetrics (90 días). UI: https://vm.lyxar.dedyn.io (solo LAN).
- **Alertas:** vmalert evalúa `apps/monitoring/configmap-vmalert-rules.yaml` y manda a Alertmanager (https://alertmanager.lyxar.dedyn.io, solo LAN) que notifica por Telegram. El token está cifrado en `sealedsecret-alertmanager-telegram.yaml`.
- **Bot nuevo:** `RESET=1 bash scripts/phase6a-metrics.sh` (pide token y detecta el chat).
- **Silenciar:** en Telegram (silenciar el chat) o en Alertmanager (Silences).
- **Restaurar en un cluster nuevo:** ArgoCD recrea todo desde Git; el token se descifra con la clave de Sealed Secrets.
