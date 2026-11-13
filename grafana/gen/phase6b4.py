import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dashlib2 import (Board, C, GOOD, WARN, BAD, INFO, th, prop, by_name, by_regex, color_of,
                      val_map, variable_query)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dashboards-src")
RI = "$__rate_interval"
UP_DOWN = val_map({"0": ("CAÍDO", BAD), "1": ("OK", GOOD)})
CPU_USED = f'100 - avg(rate(node_cpu_seconds_total{{mode="idle"}}[{RI}])) * 100'
MEM_USED = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100"
PCT_HEALTH = th((BAD, None), (WARN, 90), (GOOD, 99.9))
CLASS_COLORS = [by_name("2xx", color_of(GOOD)), by_name("3xx", color_of(C["blue"])),
                by_name("4xx", color_of(WARN)), by_name("5xx", color_of(BAD))]
HTTP_CLASSES = [(f'sum(rate(traefik_service_requests_total{{code=~"{c}.."}}[{RI}])) or vector(0)', f"{c}xx")
                for c in "2345"]
DASH = {"fill": "dash", "dash": [10, 10]}

# =====================================================================
#  1) k3s · Cluster
# =====================================================================
NS = 'namespace=~"$namespace"'
CTR = f'{NS},container!="",container!="POD"'
CTR_ALL = 'container!="",container!="POD"'

b = Board("k3s · Cluster", "k3s-pods", ["sparky", "k3s"],
          variables=[variable_query("namespace", "Namespace", "label_values(kube_pod_info, namespace)")],
          desc="Estado, capacidad y consumo del cluster k3s. Filtrá por namespace arriba a la izquierda.")

b.section("Estado del cluster")
b.stat("Nodo", ['sum(kube_node_status_condition{condition="Ready",status="true"})'], spark=False,
       thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
b.stat("Pods sanos", [f'sum(kube_pod_status_phase{{{NS},phase="Running"}}) / sum(kube_pod_status_phase{{{NS},phase=~"Running|Pending|Failed|Unknown"}}) * 100'],
       unit="percent", decimals=1, thr=PCT_HEALTH, desc="Pods Running sobre el total de pods activos (sin contar Completed).")
b.stat("Pods Running", [f'sum(kube_pod_status_phase{{{NS},phase="Running"}})'], color=INFO)
b.stat("Pods con problemas", [f'sum(kube_pod_status_phase{{{NS},phase=~"Pending|Failed|Unknown"}}) or vector(0)'],
       thr=th((GOOD, None), (WARN, 1), (BAD, 3)))
b.stat("CrashLoopBackOff", [f'sum(kube_pod_container_status_waiting_reason{{{NS},reason="CrashLoopBackOff"}}) or vector(0)'],
       thr=th((GOOD, None), (BAD, 1)))
b.stat("Reinicios (1 h)", [f'sum(increase(kube_pod_container_status_restarts_total{{{NS}}}[1h])) or vector(0)'],
       thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
b.stat("Deployments disponibles", [f'sum(kube_deployment_status_replicas_available{{{NS}}}) / sum(kube_deployment_spec_replicas{{{NS}}}) * 100'],
       unit="percent", decimals=1, thr=PCT_HEALTH)
b.stat("API server: errores 5xx", [f'(sum(rate(apiserver_request_total{{code=~"5.."}}[{RI}])) or vector(0)) / sum(rate(apiserver_request_total[{RI}])) * 100'],
       unit="percent", decimals=2, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))

b.section("Capacidad del nodo")
b.gauge("CPU en uso", CPU_USED, thr=th((GOOD, None), (WARN, 70), (BAD, 90)))
b.gauge("CPU reservada (requests)", 'sum(kube_pod_container_resource_requests{resource="cpu"}) / sum(kube_node_status_allocatable{resource="cpu"}) * 100',
        thr=th((GOOD, None), (WARN, 70), (BAD, 90)),
        desc="Lo que los pods piden al scheduler sobre lo asignable del nodo. Cerca de 100% = no entran más pods.")
b.gauge("Memoria en uso", MEM_USED, thr=th((GOOD, None), (WARN, 80), (BAD, 90)))
b.gauge("Memoria reservada (requests)", 'sum(kube_pod_container_resource_requests{resource="memory"}) / sum(kube_node_status_allocatable{resource="memory"}) * 100',
        thr=th((GOOD, None), (WARN, 70), (BAD, 90)))
b.gauge("Pods / capacidad", 'max(kubelet_running_pods) / sum(kube_node_status_allocatable{resource="pods"}) * 100',
        thr=th((GOOD, None), (WARN, 70), (BAD, 90)), desc="Pods corriendo sobre el máximo que admite el nodo (110 por defecto en k3s).")
b.gauge("PVC más lleno", 'max(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100',
        thr=th((GOOD, None), (WARN, 75), (BAD, 90)))

b.section("Cargas de trabajo")
b.ts("Pods por fase", [(f'sum by (phase) (kube_pod_status_phase{{{NS}}})', "{{phase}}")], w=8, stack=True, fill=35,
     overrides=[by_name("Running", color_of(INFO)), by_name("Pending", color_of(WARN)),
                by_name("Failed", color_of(BAD)), by_name("Succeeded", color_of(C["slate"])),
                by_name("Unknown", color_of(C["pink"]))])
b.table("Namespaces",
        [(f'count by (namespace) (kube_pod_info{{{NS}}})', ""),
         (f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CTR}}}[{RI}]))', ""),
         (f'sum by (namespace) (container_memory_working_set_bytes{{{CTR}}})', ""),
         (f'sum by (namespace) (increase(kube_pod_container_status_restarts_total{{{NS}}}[1h]))', "")],
        w=16, sort="Memoria",
        transforms=[{"id": "joinByField", "options": {"byField": "namespace", "mode": "outer"}},
                    {"id": "filterFieldsByName", "options": {"include": {"names": ["namespace", "Value #A", "Value #B", "Value #C", "Value #D"]}}},
                    {"id": "organize", "options": {"renameByName": {"namespace": "Namespace", "Value #A": "Pods", "Value #B": "CPU (núcleos)",
                                                                    "Value #C": "Memoria", "Value #D": "Reinicios 1 h"},
                                                   "indexByName": {"namespace": 0, "Value #A": 1, "Value #B": 2, "Value #C": 3, "Value #D": 4}}}],
        overrides=[by_name("Memoria", prop("unit", "bytes"), prop("custom.cellOptions", {"type": "gauge", "mode": "gradient"}),
                           prop("color", {"mode": "fixed", "fixedColor": C["violet"]}), prop("min", 0)),
                   by_name("CPU (núcleos)", prop("decimals", 2), prop("custom.cellOptions", {"type": "gauge", "mode": "gradient"}),
                           prop("color", {"mode": "fixed", "fixedColor": INFO}), prop("min", 0)),
                   by_name("Reinicios 1 h", prop("decimals", 0), prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}),
                           prop("thresholds", {"mode": "absolute", "steps": th((GOOD, None), (WARN, 1), (BAD, 10))}),
                           prop("color", {"mode": "thresholds"})),
                   by_name("Pods", prop("decimals", 0))])

b.section("Consumo de recursos")
b.ts("CPU por namespace (núcleos)", [(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CTR}}}[{RI}]))', "{{namespace}}")],
     h=9, stack=True, fill=30, legend="table", unit="short", decimals=2)
b.ts("Memoria por namespace", [(f'sum by (namespace) (container_memory_working_set_bytes{{{CTR}}})', "{{namespace}}")],
     h=9, stack=True, fill=30, legend="table", unit="bytes")
b.ts("CPU: uso vs reservado vs capacidad (todo el cluster)",
     [(f'sum(rate(container_cpu_usage_seconds_total{{{CTR_ALL}}}[{RI}]))', "Uso"),
      ('sum(kube_pod_container_resource_requests{resource="cpu"})', "Reservado"),
      ('sum(kube_node_status_allocatable{resource="cpu"})', "Capacidad")],
     unit="short", decimals=2,
     overrides=[by_name("Uso", color_of(INFO), prop("custom.fillOpacity", 35)), by_name("Reservado", color_of(C["violet"])),
                by_name("Capacidad", color_of(BAD), prop("custom.lineStyle", DASH), prop("custom.fillOpacity", 0))])
b.ts("Memoria: uso vs reservado vs capacidad (todo el cluster)",
     [(f'sum(container_memory_working_set_bytes{{{CTR_ALL}}})', "Uso"),
      ('sum(kube_pod_container_resource_requests{resource="memory"})', "Reservado"),
      ('sum(kube_node_status_allocatable{resource="memory"})', "Capacidad")],
     unit="bytes",
     overrides=[by_name("Uso", color_of(INFO), prop("custom.fillOpacity", 35)), by_name("Reservado", color_of(C["violet"])),
                by_name("Capacidad", color_of(BAD), prop("custom.lineStyle", DASH), prop("custom.fillOpacity", 0))])
b.bar("Top 10 pods por CPU", [(f'sort_desc(topk(10, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{CTR}}}[{RI}]))))', "{{namespace}}/{{pod}}")],
      w=8, h=9, mode="lcd", unit="short", decimals=3, color=INFO, minv=0)
b.bar("Top 10 pods por memoria", [(f'sort_desc(topk(10, sum by (namespace, pod) (container_memory_working_set_bytes{{{CTR}}})))', "{{namespace}}/{{pod}}")],
      w=8, h=9, mode="gradient", unit="bytes", color=C["violet"], minv=0)
b.bar("CPU throttling (top 10)",
      [(f'sort_desc(topk(10, sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{{{CTR}}}[{RI}])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{{{CTR}}}[{RI}])) * 100))', "{{namespace}}/{{pod}}")],
      w=8, h=9, mode="gradient", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 10), (BAD, 30)),
      no_value="Sin throttling",
      desc="Porcentaje de períodos en que el contenedor fue frenado por su límite de CPU.")

b.section("Red, API server y DNS")
b.ts("Tráfico de pods (todo el cluster)",
     [(f'sum(rate(container_network_receive_bytes_total{{{NS}}}[{RI}]))', "Entrada ↓"),
      (f'sum(rate(container_network_transmit_bytes_total{{{NS}}}[{RI}]))', "Salida ↑")],
     unit="Bps", overrides=[by_name("Entrada ↓", color_of(INFO)),
                            by_name("Salida ↑", color_of(C["pink"]), prop("custom.transform", "negative-Y"))])
b.ts("API server: peticiones por código", [(f'sum by (code) (rate(apiserver_request_total[{RI}]))', "{{code}}")],
     stack=True, fill=30, unit="reqps",
     overrides=[by_regex("^2.*", color_of(GOOD)), by_regex("^3.*", color_of(C["blue"])),
                by_regex("^4.*", color_of(WARN)), by_regex("^5.*", color_of(BAD))])
b.ts("API server: latencia",
     [(f'histogram_quantile(0.50, sum by (le) (rate(apiserver_request_duration_seconds_bucket{{verb!~"WATCH|CONNECT"}}[{RI}])))', "p50"),
      (f'histogram_quantile(0.95, sum by (le) (rate(apiserver_request_duration_seconds_bucket{{verb!~"WATCH|CONNECT"}}[{RI}])))', "p95"),
      (f'histogram_quantile(0.99, sum by (le) (rate(apiserver_request_duration_seconds_bucket{{verb!~"WATCH|CONNECT"}}[{RI}])))', "p99")],
     unit="s", fill=12,
     overrides=[by_name("p50", color_of(GOOD)), by_name("p95", color_of(WARN)), by_name("p99", color_of(BAD))])
b.heatmap("API server: distribución de latencia",
          f'sum by (le) (increase(apiserver_request_duration_seconds_bucket{{verb!~"WATCH|CONNECT"}}[{RI}]))',
          desc="Cada celda es cuántas peticiones cayeron en ese rango de latencia. Más brillante = más peticiones.")
b.ts("CoreDNS: respuestas por tipo", [(f'sum by (rcode) (rate(coredns_dns_responses_total[{RI}]))', "{{rcode}}")],
     stack=True, fill=30, unit="reqps",
     overrides=[by_name("NOERROR", color_of(GOOD)), by_name("NXDOMAIN", color_of(WARN)), by_name("SERVFAIL", color_of(BAD))])
b.ts("CoreDNS: latencia p99",
     [(f'histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[{RI}])))', "p99")],
     unit="s", color=C["violet"])

b.section("Volúmenes (PVC)")
b.bar("Uso de cada volumen",
      [(f'sort_desc(kubelet_volume_stats_used_bytes{{{NS}}} / kubelet_volume_stats_capacity_bytes{{{NS}}} * 100)', "{{namespace}}/{{persistentvolumeclaim}}")],
      mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 75), (BAD, 90)), no_value="Sin datos de volúmenes")
b.bar("Espacio usado por volumen",
      [(f'sort_desc(kubelet_volume_stats_used_bytes{{{NS}}})', "{{namespace}}/{{persistentvolumeclaim}}")],
      mode="gradient", unit="bytes", color=C["violet"], minv=0, no_value="Sin datos de volúmenes")
b.save(os.path.join(OUT, "k3s-pods.json"))

# =====================================================================
#  2) Sparky · Centro de mando
# =====================================================================
h = Board("Sparky · Centro de mando", "sparky-home", ["sparky", "inicio"],
          desc="Vista única: salud general, recursos, tráfico, plataforma, discos y contenedores.")
h.text("# ⚡ SPARKY · centro de mando\nk3s · plataforma · servidor · discos &nbsp;—&nbsp; se actualiza cada 30 s", h=3)

h.section("Salud general")
h.stat("Targets de métricas", ["avg(up) * 100"], w=4, unit="percent", decimals=1, thr=PCT_HEALTH, desc="Porcentaje de exporters que responden.")
h.stat("Nodo k3s", ['sum(kube_node_status_condition{condition="Ready",status="true"})'], w=4, spark=False,
       thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
h.stat("Pods sanos", ['sum(kube_pod_status_phase{phase="Running"}) / sum(kube_pod_status_phase{phase=~"Running|Pending|Failed|Unknown"}) * 100'],
       w=4, unit="percent", decimals=1, thr=PCT_HEALTH)
h.stat("Apps ArgoCD sanas", ['sum(argocd_app_info{health_status="Healthy"}) / count(argocd_app_info) * 100'],
       w=4, unit="percent", decimals=0, thr=PCT_HEALTH)
h.stat("Certificados listos", ['sum(certmanager_certificate_ready_status{condition="True"}) / count(count by (name, namespace) (certmanager_certificate_ready_status)) * 100'],
       w=4, unit="percent", decimals=0, thr=PCT_HEALTH)
h.stat("Último backup", ['time() - max(velero_backup_last_successful_timestamp)'], w=4, unit="s", decimals=1,
       thr=th((GOOD, None), (WARN, 129600), (BAD, 172800)), desc="Tiempo desde el último backup exitoso de Velero. Verde: menos de 36 h.")
h.stat("Peticiones web", [f'sum(rate(traefik_service_requests_total[{RI}]))'], w=4, unit="reqps", decimals=2, color=INFO)
h.stat("Errores 5xx web", [f'(sum(rate(traefik_service_requests_total{{code=~"5.."}}[{RI}])) or vector(0)) / sum(rate(traefik_service_requests_total[{RI}])) * 100'],
       w=4, unit="percent", decimals=2, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
h.stat("Actualizaciones pendientes", ['sum(lab_pending_updates)'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 25)), desc="Paquetes pendientes en apt, snap y flatpak.")
h.stat("Reinicio requerido", ['max(lab_reboot_required)'], w=4, spark=False, thr=th((GOOD, None), (WARN, 1)),
       mappings=val_map({"0": ("No", GOOD), "1": ("Sí", WARN)}), mode="background")
h.stat("Discos SMART OK", ['sum(lab_smart_passed) / count(lab_smart_passed) * 100'], w=4, unit="percent", decimals=0, thr=th((BAD, None), (GOOD, 100)))
h.stat("Sectores pendientes", ['sum(lab_smart_attribute_raw{name="current_pending_sector"})'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 5)),
       desc="Suma de sectores pendientes de reasignar en todos los discos.")

h.section("Recursos del servidor")
h.gauge("CPU", CPU_USED, thr=th((GOOD, None), (WARN, 70), (BAD, 90)))
h.gauge("Memoria", MEM_USED, thr=th((GOOD, None), (WARN, 80), (BAD, 90)))
h.gauge("Disco del sistema", '100 - node_filesystem_avail_bytes{mountpoint="/",fstype="ext4"} / node_filesystem_size_bytes{mountpoint="/",fstype="ext4"} * 100',
        thr=th((GOOD, None), (WARN, 75), (BAD, 90)))
h.gauge("Presión de I/O (PSI)", f'rate(node_pressure_io_stalled_seconds_total[{RI}]) * 100', thr=th((GOOD, None), (WARN, 10), (BAD, 25)),
        maxv=50, desc="Porcentaje del tiempo con procesos detenidos esperando disco. Sostenido sobre 10% = discos saturados.")
h.gauge("Temperatura de discos (máx)", 'max(lab_smart_attribute_raw{name="temperature_celsius"})', unit="celsius", minv=20, maxv=70,
        thr=th((GOOD, None), (WARN, 50), (BAD, 60)))
h.gauge("Carga por núcleo", 'node_load1 / scalar(count(count by (cpu) (node_cpu_seconds_total))) * 100', thr=th((GOOD, None), (WARN, 80), (BAD, 120)),
        maxv=150, desc="Carga de 1 min dividida por núcleos. 100% = todos los núcleos ocupados.")

h.section("Actividad")
h.ts("CPU por namespace", [(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CTR_ALL}}}[{RI}]))', "{{namespace}}")],
     w=8, stack=True, fill=30, unit="short", decimals=2, legend="none")
h.ts("Tráfico web por clase HTTP", HTTP_CLASSES, w=8, stack=True, fill=40, unit="reqps", overrides=CLASS_COLORS)
h.ts("Red del servidor", [(f'sum(rate(node_network_receive_bytes_total{{device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*|wg.*"}}[{RI}]))', "Entrada ↓"),
                          (f'sum(rate(node_network_transmit_bytes_total{{device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*|wg.*"}}[{RI}]))', "Salida ↑")],
     w=8, unit="Bps", overrides=[by_name("Entrada ↓", color_of(INFO)), by_name("Salida ↑", color_of(C["pink"]), prop("custom.transform", "negative-Y"))])
h.donut("Memoria por namespace", [(f'sum by (namespace) (container_memory_working_set_bytes{{{CTR_ALL}}})', "{{namespace}}")], w=8, h=9, unit="bytes")
h.bar("Servicios web más usados", [(f'sort_desc(topk(8, sum by (service) (rate(traefik_service_requests_total[{RI}]))))', "{{service}}")],
      w=8, h=9, mode="gradient", unit="reqps", decimals=2, color=C["violet"], minv=0, no_value="Sin tráfico")
h.bar("Pods que más CPU usan", [(f'sort_desc(topk(8, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{CTR_ALL}}}[{RI}]))))', "{{namespace}}/{{pod}}")],
      w=8, h=9, mode="lcd", unit="short", decimals=3, color=INFO, minv=0)
h.section("Plataforma")
h.table("Aplicaciones ArgoCD", [("argocd_app_info", "")], w=12, h=9,
        transforms=[{"id": "filterFieldsByName", "options": {"include": {"names": ["name", "dest_namespace", "sync_status", "health_status"]}}},
                    {"id": "organize", "options": {"renameByName": {"name": "Aplicación", "dest_namespace": "Namespace", "sync_status": "Sync", "health_status": "Salud"},
                                                   "indexByName": {"name": 0, "dest_namespace": 1, "sync_status": 2, "health_status": 3}}}],
        overrides=[by_name("Salud", prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}), prop("custom.align", "center"),
                           prop("mappings", val_map({"Healthy": ("Healthy", GOOD), "Progressing": ("Progressing", C["blue"]), "Degraded": ("Degraded", BAD),
                                                     "Missing": ("Missing", WARN), "Suspended": ("Suspended", C["slate"]), "Unknown": ("Unknown", C["slate"])}))),
                   by_name("Sync", prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}), prop("custom.align", "center"),
                           prop("mappings", val_map({"Synced": ("Synced", GOOD), "OutOfSync": ("OutOfSync", WARN), "Unknown": ("Unknown", C["slate"])})))])
h.bar("Certificados: días para vencer",
      [('sort((certmanager_certificate_expiration_timestamp_seconds - time()) / 86400)', "{{namespace}}/{{name}}")],
      w=6, h=9, mode="lcd", unit="d", decimals=0, minv=0, maxv=90, thr=th((BAD, None), (WARN, 14), (GOOD, 30)))
h.bar("MinIO: uso por bucket", [('sort_desc(max by (bucket) (minio_bucket_usage_total_bytes))', "{{bucket}}")],
      w=6, h=9, mode="gradient", unit="bytes", color=C["violet"], minv=0, no_value="Sin buckets")
h.timeline("Disponibilidad de targets (últimas horas)", [("min by (job) (up)", "{{job}}")], w=12, h=8,
           mappings=val_map({"0": ("CAÍDO", BAD), "1": ("OK", GOOD)}))
h.stat("Backups de Velero", [('sum(velero_backup_success_total) or vector(0)', "Exitosos"), ('sum(velero_backup_failure_total) or vector(0)', "Con fallos")],
       w=6, h=8, spark=False, named=True,
       overrides=[by_name("Exitosos", color_of(INFO)), by_name("Con fallos", prop("thresholds", {"mode": "absolute", "steps": th((GOOD, None), (BAD, 1))}),
                                                                prop("color", {"mode": "thresholds"}))])
h.gauge("MinIO: capacidad usada", 'max((1 - minio_cluster_capacity_usable_free_bytes / minio_cluster_capacity_usable_total_bytes) * 100)',
        w=6, h=8, thr=th((GOOD, None), (WARN, 75), (BAD, 90)))

h.section("Discos del servidor")
h.bar("Uso de cada filesystem",
      [('100 - node_filesystem_avail_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"} / node_filesystem_size_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"} * 100', "{{mountpoint}}")],
      w=8, h=9, mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 75), (BAD, 90)))
h.ts("Utilización de cada disco", [(f'rate(node_disk_io_time_seconds_total{{device=~"sd[a-d]"}}[{RI}]) * 100', "{{device}}")],
     w=8, h=9, unit="percent", maxv=100, thr=th((GOOD, None), (BAD, 90)), thr_style="dashed")
h.ts("Temperatura de discos", [('lab_smart_attribute_raw{name="temperature_celsius"}', "{{device}}")], w=8, h=9, unit="celsius", minv=20,
     thr=th((GOOD, None), (WARN, 50), (BAD, 60)), thr_style="dashed")
h.ts("Presión PSI", [(f'rate(node_pressure_io_stalled_seconds_total[{RI}]) * 100', "I/O detenido"),
                     (f'rate(node_pressure_cpu_waiting_seconds_total[{RI}]) * 100', "CPU esperando"),
                     (f'rate(node_pressure_memory_stalled_seconds_total[{RI}]) * 100', "Memoria detenida")],
     unit="percent", overrides=[by_name("I/O detenido", color_of(BAD)), by_name("CPU esperando", color_of(INFO)), by_name("Memoria detenida", color_of(C["violet"]))])
h.ts("Lectura / escritura de discos",
     [(f'sum(rate(node_disk_read_bytes_total{{device=~"sd[a-d]"}}[{RI}]))', "Lectura ↓"),
      (f'sum(rate(node_disk_written_bytes_total{{device=~"sd[a-d]"}}[{RI}]))', "Escritura ↑")],
     unit="Bps", overrides=[by_name("Lectura ↓", color_of(INFO)), by_name("Escritura ↑", color_of(C["pink"]), prop("custom.transform", "negative-Y"))])

h.section("Docker y LocalStack")
h.stat("Docker", ["lab_docker_up"], w=4, h=5, spark=False, thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
h.stat("LocalStack", ["lab_localstack_up"], w=4, h=5, spark=False, thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
h.stat("Servicios de LocalStack activos", ["sum(lab_localstack_service_running)"], w=4, h=5, color=INFO, spark=False)
h.stat("Contenedores corriendo", ["sum(lab_docker_container_running)"], w=4, h=5, color=INFO, spark=False)
h.ts("CPU de contenedores Docker", [("lab_docker_container_cpu_percent", "{{name}}")], w=8, h=5, unit="percent")
h.save(os.path.join(OUT, "sparky-home.json"))
print("ok")
