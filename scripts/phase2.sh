#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
: "${GH_USER:?exportá GH_USER}"
DOM=lyxar.dedyn.io
REPO=git@github.com:$GH_USER/homelab.git
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/homelab_argocd -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
cd ~/homelab
mkdir -p bootstrap clusters/sparky platform/{argocd,cert-manager} apps monitoring terraform docs .github/workflows

# --- util para exportar objetos vivos a YAML limpio (se reutiliza en la Fase 3)
cat > scripts/lib.sh <<'EOF'
# uso: export_clean <kind> <name> [namespace] > archivo.yaml
export_clean(){
  local ns=(); [ -n "${3:-}" ] && ns=(-n "$3")
  kubectl get "$1" "$2" "${ns[@]}" -o json | jq 'del(.status,.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.metadata.ownerReferences,.metadata.selfLink) | del(.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
   | python3 -c 'import sys,json,yaml;print(yaml.safe_dump(json.load(sys.stdin),sort_keys=False))'
}
EOF
source scripts/lib.sh

cat > .gitignore <<'EOF'
SECRETS*
*.key
*.pem
*.tfstate*
.terraform/
homelab-backup/
EOF

cat > README.md <<EOF
# homelab (k3s en sparky)
GitOps con ArgoCD. Todo cambio va por Git. Dominio: *.$DOM
- \`bootstrap/\`  objetos que se aplican a mano una sola vez
- \`platform/\`   infra base (argocd, cert-manager, traefik...) – cada carpeta es una Application
- \`apps/\`        aplicaciones (media, minio, ...)
- \`monitoring/\` observabilidad
- \`terraform/\`  labs de IaC (floci/MinIO)
- \`scripts/\`    lab-check.sh y utilidades
- \`docs/\`       arquitectura y runbooks (DR.md)
Salud del lab: \`scripts/lab-check.sh\`
EOF

export_clean clusterissuer letsencrypt > platform/cert-manager/clusterissuer-letsencrypt.yaml

cat > platform/argocd/ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  ingressClassName: traefik
  tls:
    - hosts: [argocd.$DOM]
      secretName: argocd-tls
  rules:
    - host: argocd.$DOM
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

cat > bootstrap/appset-platform.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: $REPO
        revision: main
        directories:
          - path: platform/*
  template:
    metadata:
      name: 'platform-{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: $REPO
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd   # los manifiestos deben traer su propio namespace
      syncPolicy:
        automated: { prune: false, selfHeal: true }
        syncOptions: [ServerSideApply=true]
EOF

echo "== Push a GitHub =="
git init -q -b main 2>/dev/null; git remote remove origin 2>/dev/null; git remote add origin "$REPO"
git add -A && git commit -qm "bootstrap: estructura inicial + argocd ingress + issuer" 
git push -u origin main -q && ok "repo publicado" || { bad "falló el push (¿agregaste la deploy key con write?)"; exit 1; }

echo "== ArgoCD: modo insecure (TLS lo termina Traefik) y credenciales del repo =="
kubectl -n argocd patch cm argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}' >/dev/null
kubectl -n argocd rollout restart deploy/argocd-server >/dev/null
kubectl -n argocd create secret generic repo-homelab --from-literal=type=git --from-literal=url="$REPO" \
  --from-file=sshPrivateKey=$HOME/.ssh/homelab_argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n argocd label secret repo-homelab argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
kubectl -n argocd rollout status deploy/argocd-server --timeout=120s >/dev/null && ok "argocd-server reiniciado"

echo "== DNS =="
dig +short argocd.$DOM | grep -q . && ok "argocd.$DOM resuelve a $(dig +short argocd.$DOM)" \
  || bad "argocd.$DOM NO resuelve: en desec.io agregá un registro A '*' con tu IP pública (o CNAME * -> $DOM)"

echo "== Aplico el ApplicationSet =="
kubectl apply -f bootstrap/appset-platform.yaml >/dev/null
sleep 20
kubectl -n argocd get applications.argoproj.io

echo "== Certificado de ArgoCD =="
timeout 120 bash -c 'until kubectl -n argocd get certificate argocd-tls >/dev/null 2>&1; do sleep 3; done' || bad "no se creó el Certificate"
kubectl -n argocd wait --for=condition=Ready certificate/argocd-tls --timeout=300s >/dev/null 2>&1 \
  && ok "argocd-tls emitido" || bad "cert no emitido: kubectl -n argocd describe certificate argocd-tls"

echo; echo "Password inicial admin: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
echo "URL: https://argocd.$DOM"
