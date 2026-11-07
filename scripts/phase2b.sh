#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
DOM=lyxar.dedyn.io
API=https://desec.io/api/v1/domains/$DOM/rrsets/
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

echo "== 1) Token de deSEC (el de dedyn-updater) =="
REF=$(kubectl -n kube-system get deploy dedyn-updater -o json | jq -r '.spec.template.spec.containers[0].env[]|select(.name=="TOKEN")|.valueFrom.secretKeyRef|"\(.name) \(.key)"')
read -r SN SK <<<"$REF"
TOKEN=$(kubectl -n kube-system get secret "$SN" -o json | jq -r --arg k "$SK" '.data[$k]' | base64 -d)
[ -n "$TOKEN" ] && ok "token leído del Secret $SN" || { bad "no pude leer el token"; exit 1; }

CODE=$(curl -s -o "$TMP" -w '%{http_code}' -H "Authorization: Token $TOKEN" "$API")
if [ "$CODE" != 200 ]; then
  bad "la API de deSEC respondió $CODE. Ese token no sirve para la API REST."
  echo "     Creá uno en https://desec.io -> Token Management (sin restricciones) y avisame."; exit 1
fi
ok "API de deSEC OK. Registros actuales:"
jq -r '.[]|"     \(if .subname=="" then "@" else .subname end)  \(.type)  \(.records|join(","))"' "$TMP"
RR=$(cat "$TMP")

echo "== 2) Wildcard *.$DOM -> $DOM (CNAME) =="
CODE=$(curl -s -o "$TMP" -w '%{http_code}' -X PATCH -H "Authorization: Token $TOKEN" -H 'Content-Type: application/json' "$API" \
  -d '[{"subname":"*","type":"CNAME","ttl":3600,"records":["'$DOM'."]}]')
case $CODE in 200|201) ok "wildcard creado/actualizado";; *) bad "falló ($CODE):"; cat "$TMP"; exit 1;; esac
R=""; for i in $(seq 1 12); do R=$(dig +short @ns1.desec.io zzz-random.$DOM | tr '\n' ' '); [ -n "$R" ] && break; sleep 5; done
[ -n "$R" ] && ok "servidor autoritativo: zzz-random.$DOM -> $R" || { bad "el wildcard no aparece en ns1.desec.io"; exit 1; }

echo "== 3) Borro A estáticos de floci (ahora los cubre el wildcard) =="
for s in floci floci-ui; do
  N=$(jq --arg s "$s" '[.[]|select(.subname==$s)]|length' <<<"$RR")
  A=$(jq --arg s "$s" '[.[]|select(.subname==$s and .type=="A")]|length' <<<"$RR")
  if [ "$N" = 1 ] && [ "$A" = 1 ]; then
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Token $TOKEN" "${API}${s}/A/")
    [ "$CODE" = 204 ] && ok "A de $s eliminado" || bad "no pude borrar $s ($CODE)"
  else echo "  - $s: lo dejo como está (tiene otros registros o ya no existe)"; fi
done
sleep 5
for s in floci floci-ui; do echo "     $s -> $(dig +short @ns1.desec.io $s.$DOM | tr '\n' ' ')"; done

echo "== 4) Esperando que resuelva localmente =="
kubectl -n kube-system rollout restart deploy/coredns >/dev/null && kubectl -n kube-system rollout status deploy/coredns --timeout=90s >/dev/null
for h in argocd grafana; do
  for i in $(seq 1 12); do [ -n "$(dig +short $h.$DOM | head -1)" ] && break; sleep 5; done
  [ -n "$(dig +short $h.$DOM | head -1)" ] && ok "$h.$DOM resuelve" \
    || bad "$h.$DOM aún no resuelve localmente (caché negativa de tu router/ISP, puede tardar hasta 1h). Reejecutá el script más tarde."
done

echo "== 5) Reintento de certificados =="
for ns in argocd monitoring; do
  kubectl -n $ns delete challenges,orders,certificaterequests --all --wait=false >/dev/null 2>&1
  kubectl -n $ns delete pod,svc,ingress -l acme.cert-manager.io/http01-solver=true --ignore-not-found >/dev/null 2>&1
done
for c in argocd/argocd-tls monitoring/grafana-tls; do
  ns=${c%/*}; n=${c#*/}
  if kubectl -n $ns wait --for=condition=Ready certificate/$n --timeout=300s >/dev/null 2>&1; then ok "$c emitido"
  else bad "$c sin emitir. Motivo:"; kubectl -n $ns get challenges -o jsonpath='{range .items[*]}     {.status.reason}{"\n"}{end}'; fi
done

echo "== 6) Backup de la DB de k3s =="
BK=$(ls -dt ~/homelab-backup/*/ | head -1)
sudo tar czf "$BK/k3s-server.tgz" -C /var/lib/rancher/k3s server/db server/token server/tls server/cred; RC=$?
if [ $RC -le 1 ]; then
  sudo chown "$USER" "$BK/k3s-server.tgz"; chmod 600 "$BK/k3s-server.tgz"
  ok "k3s-server.tgz ($(du -h "$BK/k3s-server.tgz" | cut -f1), $(tar tzf "$BK/k3s-server.tgz" | wc -l) archivos; tar rc=$RC)"
else bad "tar falló con código $RC (ver error arriba)"; fi
