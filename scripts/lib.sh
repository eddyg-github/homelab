# uso: export_clean <kind> <name> [namespace] > archivo.yaml
export_clean(){
  local ns=(); [ -n "${3:-}" ] && ns=(-n "$3")
  kubectl get "$1" "$2" "${ns[@]}" -o json | jq 'del(.status,.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.metadata.ownerReferences,.metadata.selfLink) | del(.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
   | python3 -c 'import sys,json,yaml;print(yaml.safe_dump(json.load(sys.stdin),sort_keys=False))'
}
