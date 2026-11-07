#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
cd ~/homelab
CN=sealed-secrets-controller; CNS=kube-system
BK=~/homelab-backup; mkdir -p "$BK"; chmod 700 "$BK"
SECRETS="minio/minio-env monitoring/grafana-env kube-system/dedyn-token"

refresh(){
  kubectl -n argocd annotate applicationset platform argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1
  for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done
}
hash_of(){ kubectl -n "$1" get secret "$2" -o json | jq -S .data | sha256sum | cut -c1-16; }

echo "== 0) Pre-chequeos =="
for s in $SECRETS; do kubectl -n "${s%/*}" get secret "${s#*/}" >/dev/null 2>&1 && ok "existe $s" || { bad "falta el Secret $s"; exit 1; }; done
declare -A H0; for s in $SECRETS; do H0[$s]=$(hash_of "${s%/*}" "${s#*/}"); done

echo "== 1) Descargo controlador y kubeseal =="
TAG=$(curl -sL -o /dev/null -w '%{url_effective}' https://github.com/bitnami/sealed-secrets/releases/latest | sed 's#.*/tag/##')
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { bad "versión inválida: $TAG"; exit 1; }
V=${TAG#v}; echo "   versión: $TAG"
mkdir -p platform/sealed-secrets
curl -sSL -f -o platform/sealed-secrets/controller.yaml "https://github.com/bitnami/sealed-secrets/releases/download/$TAG/controller.yaml" \
  && ok "controller.yaml descargado" || { bad "falló la descarga del controlador"; exit 1; }
if ! command -v kubeseal >/dev/null || ! kubeseal --version 2>/dev/null | grep -q "$V"; then
  curl -sSL -f -o /tmp/kubeseal.tgz "https://github.com/bitnami/sealed-secrets/releases/download/$TAG/kubeseal-$V-linux-amd64.tar.gz" \
    && tar xzf /tmp/kubeseal.tgz -C /tmp kubeseal && sudo install -m 755 /tmp/kubeseal /usr/local/bin/kubeseal && rm -f /tmp/kubeseal /tmp/kubeseal.tgz \
    && ok "kubeseal instalado" || { bad "no pude instalar kubeseal"; exit 1; }
else ok "kubeseal ya está en $V"; fi

echo "== 2) Marco los Secrets actuales como adoptables =="
for s in $SECRETS; do kubectl -n "${s%/*}" annotate secret "${s#*/}" sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null && ok "$s"; done

echo "== 3) Controlador vía ArgoCD =="
git add -A
git diff --cached --quiet || git commit -qm "platform: sealed-secrets controller $TAG"
git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh
for i in $(seq 1 40); do
  kubectl get crd sealedsecrets.bitnami.com >/dev/null 2>&1 && kubectl -n $CNS get deploy $CN >/dev/null 2>&1 && break; sleep 10
done
kubectl -n $CNS rollout status deploy/$CN --timeout=240s >/dev/null 2>&1 && ok "controlador Ready" \
  || { bad "el controlador no levantó. Imagen y estado:"; kubectl -n $CNS get deploy $CN -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>&1; kubectl -n $CNS get pods 2>&1 | grep sealed; kubectl -n argocd get application platform-sealed-secrets 2>&1; exit 1; }

echo "== 4) Backup de la clave de recuperación =="
for i in $(seq 1 20); do [ -n "$(kubectl -n $CNS get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name 2>/dev/null)" ] && break; sleep 3; done
( umask 077; kubectl -n $CNS get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$BK/sealed-secrets-master-key.yaml" )
grep -q 'tls.key' "$BK/sealed-secrets-master-key.yaml" && ok "clave guardada en $BK/sealed-secrets-master-key.yaml" || { bad "no pude guardar la clave"; exit 1; }
grep -q 'master-key' .gitignore || echo '*master-key*' >> .gitignore

echo "== 5) Cifro los Secrets =="
kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt && ok "certificado público guardado (es público, va a Git)" || { bad "no pude obtener el certificado"; exit 1; }
seal(){ # ns name destfile
  kubectl -n "$1" get secret "$2" -o json \
   | jq '{apiVersion:"v1",kind:"Secret",metadata:{name:.metadata.name,namespace:.metadata.namespace},type:(.type // "Opaque"),data:.data}' \
   | kubeseal --cert sealed-secrets-pub.crt --format yaml > "$3" && [ -s "$3" ] && ok "$1/$2 -> $3" || { bad "no pude cifrar $1/$2"; rm -f "$3"; return 1; }
}
mkdir -p platform/dedyn
seal minio minio-env apps/minio/sealedsecret-minio-env.yaml || exit 1
seal monitoring grafana-env apps/monitoring/sealedsecret-grafana-env.yaml || exit 1
seal kube-system dedyn-token platform/dedyn/sealedsecret-dedyn-token.yaml || exit 1

echo "== 6) Chequeo: ningún valor sensible en texto plano en el repo =="
LEAK=0
for s in $SECRETS; do
  while IFS= read -r v; do
    [ ${#v} -ge 8 ] || continue
    if grep -rqF --exclude-dir=.git -- "$v" . ; then bad "un valor de ${s#*/} aparece en claro en el repo"; LEAK=1; fi
  done < <(kubectl -n "${s%/*}" get secret "${s#*/}" -o json | jq -r '.data|to_entries[]|select(.key|test("PASS|SECRET|TOKEN|KEY";"i"))|.value|@base64d')
done
[ $LEAK = 0 ] && ok "sin valores sensibles en claro" || { echo "   NO se sube nada. Revisá el repo."; exit 1; }

echo "== 7) Push y sincronización =="
cat > docs/SECRETS.md <<'MD'
# Secretos (Sealed Secrets)
- Los `SealedSecret` en Git están cifrados; solo el controlador del cluster los descifra.
- Certificado público: `sealed-secrets-pub.crt` (para cifrar nuevos: `kubeseal --cert sealed-secrets-pub.crt --format yaml < secret.yaml > sealedsecret.yaml`).
- **Clave de recuperación**: `sealed-secrets-master-key.yaml` (NO está en Git; guardala fuera de sparky).
## Recuperar en un cluster nuevo
1. Instalar k3s y ArgoCD.
2. Restaurar la clave ANTES de que el controlador arranque: `kubectl apply -f sealed-secrets-master-key.yaml`
3. Crear a mano el acceso de ArgoCD al repo (deploy key SSH): Secret `repo-homelab` en `argocd` con label `argocd.argoproj.io/secret-type=repository`.
4. Aplicar `bootstrap/` y ArgoCD reconstruye todo, incluidos los secretos.
MD
git add -A
git commit -qm "secrets: SealedSecrets de minio, grafana y dedyn-token + docs" && git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh
for i in $(seq 1 30); do
  N=$(kubectl get sealedsecret -A --no-headers 2>/dev/null | wc -l); [ "$N" -ge 3 ] && break; sleep 10
done
sleep 20
kubectl get sealedsecret -A
echo "== 8) Los Secrets siguen idénticos =="
for s in $SECRETS; do
  H1=$(hash_of "${s%/*}" "${s#*/}")
  [ "$H1" = "${H0[$s]}" ] && ok "$s sin cambios" || bad "$s cambió ($H1 vs ${H0[$s]})"
done
kubectl -n argocd get applications.argoproj.io
