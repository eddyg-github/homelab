#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }

add(){ # app puerto ruta
  local app=$1 port=$2 path=$3
  echo "-- $app: $path"
  kubectl -n media exec deploy/$app -- sh -c "[ -d '$path' ]" 2>/dev/null || { bad "la carpeta $path no existe dentro del pod"; return 1; }
  local out
  out=$(kubectl -n media exec deploy/$app -- sh -c '
    K=$(grep -o "<ApiKey>[^<]*" /config/config.xml | cut -d">" -f2)
    H="X-Api-Key: $K"
    if curl -s -m 10 -H "$H" http://localhost:'$port'/api/v3/rootfolder | grep -q "\"path\": *\"'$path'\""; then echo EXISTS; exit 0; fi
    curl -sS -m 20 -H "$H" -H "Content-Type: application/json" -X POST -d "{\"path\":\"'$path'\"}" -w "\nHTTP %{http_code}" http://localhost:'$port'/api/v3/rootfolder
  ' 2>&1)
  if [ "$out" = EXISTS ]; then ok "ya estaba configurada"
  elif echo "$out" | grep -q 'HTTP 20'; then ok "agregada"
  else
    bad "no se pudo agregar. Respuesta:"; echo "$out" | head -c 500; echo
    echo "   dueño de la carpeta: $(kubectl -n media exec deploy/$app -- stat -c 'uid=%u gid=%g modo=%a' "$path" 2>&1)"
    echo "   usuario de la app:   $(kubectl -n media exec deploy/$app -- id 2>&1)"
    return 1
  fi
  kubectl -n media exec deploy/$app -- sh -c '
    K=$(grep -o "<ApiKey>[^<]*" /config/config.xml | cut -d">" -f2)
    curl -s -m 10 -H "X-Api-Key: $K" http://localhost:'$port'/api/v3/rootfolder' | jq -r '.[]|"   root folder: \(.path)  accesible=\(.accessible)  libre=\((.freeSpace/1073741824)|floor)GB"'
}

add sonarr 8989 /tv/series
add radarr 7878 /movies/movies
