#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
cd ~/homelab
CN=sealed-secrets-controller; CNS=kube-system; BK=~/homelab-backup
rand(){ head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
hash_of(){ kubectl -n "$1" get secret "$2" -o json | jq -S .data | sha256sum | cut -c1-16; }
refresh(){ for a in $(kubectl -n argocd get applications.argoproj.io -o name); do kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1; done; }

echo "== 0) Estado inicial =="
kubectl -n $CNS get deploy $CN >/dev/null 2>&1 && ok "controlador presente" || { bad "falta el controlador (corré antes phase4-sealed.sh)"; exit 1; }
[ -s sealed-secrets-pub.crt ] || kubeseal --fetch-cert --controller-name=$CN --controller-namespace=$CNS > sealed-secrets-pub.crt
OLDMINIO=$(kubectl -n minio get secret minio-env -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)
OLDFB=$(python3 - <<'PY'
import yaml,re
o=yaml.safe_load(open('apps/filebrowser/deployment-filebrowser.yaml'))
s=o['spec']['template']['spec']
for c in s.get('initContainers',[])+s['containers']:
    for a in (c.get('command') or [])+(c.get('args') or []):
        m=re.search(r'users add admin (\S+)',a)
        if m and m.group(1)!='"$FB_ADMIN_PASSWORD"': print(m.group(1)); raise SystemExit
PY
)
HG=$(hash_of monitoring grafana-env); HD=$(hash_of kube-system dedyn-token)
ok "valores viejos leídos (no se muestran)"

echo "== 1) Credenciales nuevas (guardadas en archivo local, no se imprimen) =="
NEWMINIO=$(rand); NEWFB=$(rand)
( umask 077; printf 'MinIO  usuario: %s  contraseña: %s\nFilebrowser  usuario: admin  contraseña: %s\n' \
  "$(kubectl -n minio get secret minio-env -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)" "$NEWMINIO" "$NEWFB" > $BK/new-credentials.txt )
ok "guardadas en $BK/new-credentials.txt"

echo "== 2) Cifro los Secrets nuevos =="
kubectl -n minio get secret minio-env -o json | jq --arg p "$NEWMINIO" \
 '{apiVersion:"v1",kind:"Secret",metadata:{name:.metadata.name,namespace:.metadata.namespace},type:(.type//"Opaque"),data:(.data + {MINIO_ROOT_PASSWORD:($p|@base64)})}' \
 | kubeseal --cert sealed-secrets-pub.crt --format yaml > apps/minio/sealedsecret-minio-env.yaml && ok "minio-env" || { bad "minio-env"; exit 1; }
jq -n --arg p "$NEWFB" '{apiVersion:"v1",kind:"Secret",metadata:{name:"filebrowser-env",namespace:"default"},type:"Opaque",data:{FB_ADMIN_PASSWORD:($p|@base64)}}' \
 | kubeseal --cert sealed-secrets-pub.crt --format yaml > apps/filebrowser/sealedsecret-filebrowser-env.yaml && ok "filebrowser-env" || { bad "filebrowser-env"; exit 1; }
for f in apps/monitoring/sealedsecret-grafana-env.yaml platform/dedyn/sealedsecret-dedyn-token.yaml; do [ -s $f ] && ok "ya existe $f" || { bad "falta $f"; exit 1; }; done

echo "== 2b) Filebrowser: la contraseña sale del Deployment =="
python3 - <<'PY' || { echo "  ❌ no encontré el comando de init en el Deployment"; exit 1; }
import yaml,re,sys
f='apps/filebrowser/deployment-filebrowser.yaml'
o=yaml.safe_load(open(f)); s=o['spec']['template']['spec']; done=False
for c in s.get('initContainers',[])+s['containers']:
    for k in ('command','args'):
        L=c.get(k) or []
        for i,a in enumerate(L):
            if re.search(r'users add admin \S+ --perm',a):
                L[i]=re.sub(r'users add admin \S+ --perm','users add admin "$FB_ADMIN_PASSWORD" --perm',a)
                env=[e for e in c.get('env',[]) if e['name']!='FB_ADMIN_PASSWORD']
                env.append({'name':'FB_ADMIN_PASSWORD','valueFrom':{'secretKeyRef':{'name':'filebrowser-env','key':'FB_ADMIN_PASSWORD'}}})
                c['env']=env; done=True
if not done: sys.exit(1)
open(f,'w').write(yaml.safe_dump(o,sort_keys=False))
PY
ok "Deployment editado"

echo "== 3) Chequeo de fugas (valores viejos y nuevos) =="
LEAK=0
chk(){ [ ${#1} -ge 8 ] || return 0; grep -rqF --exclude-dir=.git -- "$1" . && { bad "$2 aparece en claro en el repo"; LEAK=1; }; }
chk "$OLDMINIO" "contraseña vieja de MinIO"; [ -n "$OLDFB" ] && chk "$OLDFB" "contraseña vieja de Filebrowser"
chk "$NEWMINIO" "contraseña nueva de MinIO"; chk "$NEWFB" "contraseña nueva de Filebrowser"
for s in monitoring/grafana-env kube-system/dedyn-token; do
  while IFS= read -r v; do chk "$v" "valor de ${s#*/}"; done < <(kubectl -n "${s%/*}" get secret "${s#*/}" -o json | jq -r '.data|to_entries[]|select(.key|test("PASS|SECRET|TOKEN|KEY";"i"))|.value|@base64d')
done
[ $LEAK = 0 ] && ok "sin valores sensibles en claro" || { echo "   NO se publica nada."; exit 1; }

echo "== 4) Documentación, commit y push =="
mkdir -p docs
cat > docs/SECRETS.md <<'MD'
# Secretos (Sealed Secrets)
- Los `SealedSecret` en Git están cifrados; solo el controlador del cluster los descifra.
- Certificado público: `sealed-secrets-pub.crt`. Para cifrar uno nuevo:
  `kubeseal --cert sealed-secrets-pub.crt --format yaml < secret.yaml > sealedsecret.yaml`
- **Clave de recuperación**: `sealed-secrets-master-key.yaml` (NO está en Git; guardarla fuera del servidor).
## Recuperar en un cluster nuevo
1. Instalar k3s y ArgoCD.
2. Restaurar la clave ANTES de que arranque el controlador: `kubectl apply -f sealed-secrets-master-key.yaml`
3. Crear a mano el Secret `repo-homelab` en `argocd` (deploy key SSH, label `argocd.argoproj.io/secret-type=repository`).
4. Aplicar `bootstrap/` y ArgoCD reconstruye todo, incluidos los secretos.
MD
grep -q 'master-key' .gitignore || echo '*master-key*' >> .gitignore
git add -A && git commit -qm "secrets: SealedSecrets (minio, grafana, dedyn, filebrowser); rotar credenciales de minio y filebrowser" && git push -q && ok "push OK" || { bad "push falló"; exit 1; }
refresh

echo "== 5) Esperando que el controlador cree los Secrets nuevos (máx 6 min) =="
for i in $(seq 1 36); do
  [ "$(kubectl -n minio get secret minio-env -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' 2>/dev/null | base64 -d)" = "$NEWMINIO" ] \
   && kubectl -n default get secret filebrowser-env >/dev/null 2>&1 && break; sleep 10
done
[ "$(kubectl -n minio get secret minio-env -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)" = "$NEWMINIO" ] && ok "minio-env con la clave nueva" || { bad "minio-env no se actualizó. Revisá: kubectl -n minio describe sealedsecret minio-env"; exit 1; }
kubectl -n default get secret filebrowser-env >/dev/null 2>&1 && ok "filebrowser-env creado" || { bad "falta filebrowser-env"; exit 1; }

echo "== 6) Reinicios con las claves nuevas =="
kubectl -n minio rollout restart deploy/minio >/dev/null
for i in $(seq 1 24); do
  kubectl -n default get deploy filebrowser -o json | jq -e '[.spec.template.spec.initContainers[]?,.spec.template.spec.containers[]|.env[]?|select(.name=="FB_ADMIN_PASSWORD")]|length>0' >/dev/null && break
  refresh; sleep 15
done
kubectl -n default rollout status deploy/filebrowser --timeout=180s >/dev/null 2>&1
kubectl -n default exec deploy/filebrowser -c filebrowser -- cat /database/filebrowser.db > $BK/filebrowser.db.bak-$(date +%s) 2>/dev/null && ok "copia de la base de Filebrowser en $BK" || echo "  (no pude copiar la base; sigo)"
chmod 600 $BK/filebrowser.db.bak-* 2>/dev/null
kubectl -n default exec deploy/filebrowser -c filebrowser -- rm -f /database/filebrowser.db && ok "base vieja eliminada"
kubectl -n default rollout restart deploy/filebrowser >/dev/null
kubectl -n minio rollout status deploy/minio --timeout=180s >/dev/null 2>&1 && ok "minio Ready" || bad "minio no Ready"
kubectl -n default rollout status deploy/filebrowser --timeout=180s >/dev/null 2>&1 && ok "filebrowser Ready" || bad "filebrowser no Ready"
sleep 15

echo "== 7) Verificación =="
kubectl -n default exec deploy/filebrowser -c filebrowser -- wget -qO- --header 'Content-Type: application/json' --post-data "{\"username\":\"admin\",\"password\":\"$NEWFB\"}" http://localhost:8080/api/login 2>/dev/null | grep -q eyJ \
  && ok "login de Filebrowser con la clave nueva" || bad "el login de Filebrowser no funcionó"
[ "$(kubectl -n minio exec deploy/minio -- printenv MINIO_ROOT_PASSWORD 2>/dev/null)" = "$NEWMINIO" ] && ok "MinIO corre con la clave nueva" || bad "MinIO no tomó la clave nueva"
[ "$(hash_of monitoring grafana-env)" = "$HG" ] && ok "grafana-env sin cambios" || bad "grafana-env cambió"
[ "$(hash_of kube-system dedyn-token)" = "$HD" ] && ok "dedyn-token sin cambios" || bad "dedyn-token cambió"
kubectl get sealedsecret -A
kubectl -n argocd get applications.argoproj.io
echo; echo ">>> Tus claves nuevas: cat $BK/new-credentials.txt"
