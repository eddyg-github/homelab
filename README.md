# homelab (k3s en sparky)
GitOps con ArgoCD. Todo cambio va por Git. Dominio: *.lyxar.dedyn.io
- `bootstrap/`  objetos que se aplican a mano una sola vez
- `platform/`   infra base (argocd, cert-manager, traefik...) – cada carpeta es una Application
- `apps/`        aplicaciones (media, minio, ...)
- `monitoring/` observabilidad
- `terraform/`  labs de IaC (floci/MinIO)
- `scripts/`    lab-check.sh y utilidades
- `docs/`       arquitectura y runbooks (DR.md)
Salud del lab: `scripts/lab-check.sh`
