import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dashlib2 import (Board, C, GOOD, WARN, BAD, INFO, th, prop, by_name, by_regex, color_of,
                      val_map, variable_query)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dashboards-src")
RI = "$__rate_interval"
VIOLET, PINK, BLUE, SLATE = C["violet"], C["pink"], C["blue"], C["slate"]
UP_DOWN = val_map({"0": ("CAÍDO", BAD), "1": ("OK", GOOD)})
PCT_HEALTH = th((BAD, None), (WARN, 90), (GOOD, 99.9))
CPU_USED = f'100 - avg(rate(node_cpu_seconds_total{{mode="idle"}}[{RI}])) * 100'
MEM_USED = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100"
NETF = 'device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*|wg.*"'
DISK = 'device=~"sd[a-d]"'
CODE_COLORS = [by_regex("^2.*", color_of(GOOD)), by_regex("^3.*", color_of(BLUE)),
               by_regex("^4.*", color_of(WARN)), by_regex("^5.*", color_of(BAD))]
CLASS_COLORS = [by_name("2xx", color_of(GOOD)), by_name("3xx", color_of(BLUE)),
                by_name("4xx", color_of(WARN)), by_name("5xx", color_of(BAD))]
HTTP_CLASSES = [(f'sum(rate(traefik_service_requests_total{{code=~"{c}.."}}[{RI}])) or vector(0)', f"{c}xx") for c in "2345"]
NEG = lambda name, c: by_name(name, color_of(c), prop("custom.transform", "negative-Y"))
SMART = 'lab_smart_attribute_raw'

# =====================================================================
#  1) Servidor y discos  (reemplaza a servidor-discos y servidor-recursos)
# =====================================================================
s = Board("Servidor y discos", "servidor-discos", ["sparky", "host"],
          desc="CPU, memoria, red, discos, salud SMART y mantenimiento del host.")
s.section("Estado general")
s.stat("CPU usada", [CPU_USED], w=4, unit="percent", decimals=0, thr=th((GOOD, None), (WARN, 70), (BAD, 90)))
s.stat("Memoria usada", [MEM_USED], w=4, unit="percent", decimals=0, thr=th((GOOD, None), (WARN, 80), (BAD, 90)))
s.stat("Swap usada", ["node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes"], w=4, unit="bytes",
       thr=th((GOOD, None), (WARN, 512 * 1024**2), (BAD, 2 * 1024**3)))
s.stat("Carga (1 min)", ["node_load1"], w=4, decimals=2, thr=th((GOOD, None), (WARN, 4), (BAD, 8)), desc="El equipo tiene 4 núcleos: cerca de 4 = al límite.")
s.stat("Tiempo encendido", ["time() - node_boot_time_seconds"], w=4, unit="s", decimals=0, color=INFO, spark=False)
s.stat("Presión de I/O (PSI)", [f"rate(node_pressure_io_stalled_seconds_total[{RI}]) * 100"], w=4, unit="percent", decimals=1,
       thr=th((GOOD, None), (WARN, 10), (BAD, 25)), desc="Tiempo con procesos detenidos esperando disco.")
s.stat("Discos SMART OK", ["sum(lab_smart_passed) / count(lab_smart_passed) * 100"], w=4, unit="percent", decimals=0, thr=th((BAD, None), (GOOD, 100)))
s.stat("Sectores pendientes", [f'sum({SMART}{{name="current_pending_sector"}})'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
s.stat("Sectores reubicados", [f'sum({SMART}{{name="reallocated_sector_ct"}})'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
s.stat("CRC nuevos (24 h)", [f'sum(delta({SMART}{{name="udma_crc_error_count"}}[24h]))'], w=4, thr=th((GOOD, None), (BAD, 1)),
       desc="Errores de cable/puerto SATA aparecidos en las últimas 24 h. 0 = el contador histórico no está creciendo.")
s.stat("Temperatura máx. discos", [f'max({SMART}{{name="temperature_celsius"}})'], w=4, unit="celsius", thr=th((GOOD, None), (WARN, 50), (BAD, 60)))
s.stat("Horas de uso (máx)", [f'max({SMART}{{name="power_on_hours"}})'], w=4, unit="h", decimals=0, color=SLATE, spark=False)

s.section("CPU, memoria y red")
s.ts("CPU por modo (% del total)",
     [(f'sum by (mode) (rate(node_cpu_seconds_total{{mode!="idle"}}[{RI}])) / scalar(count(count by (cpu) (node_cpu_seconds_total))) * 100', "{{mode}}")],
     w=8, unit="percent", maxv=100, stack=True, fill=35)
s.ts("Memoria", [("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "Usada"),
                 ("node_memory_Cached_bytes + node_memory_Buffers_bytes", "Caché y buffers"),
                 ("node_memory_MemTotal_bytes", "Total")], w=8, unit="bytes",
     overrides=[by_name("Usada", color_of(INFO), prop("custom.fillOpacity", 35)), by_name("Caché y buffers", color_of(VIOLET)),
                by_name("Total", color_of(BAD), prop("custom.lineStyle", {"fill": "dash", "dash": [10, 10]}), prop("custom.fillOpacity", 0))])
s.ts("Red del servidor", [(f"sum(rate(node_network_receive_bytes_total{{{NETF}}}[{RI}]))", "Entrada ↓"),
                         (f"sum(rate(node_network_transmit_bytes_total{{{NETF}}}[{RI}]))", "Salida ↑")],
     w=8, unit="Bps", overrides=[by_name("Entrada ↓", color_of(INFO)), NEG("Salida ↑", PINK)])

s.section("Discos")
s.bar("Uso de cada filesystem",
      [('100 - node_filesystem_avail_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"} / node_filesystem_size_bytes{fstype=~"ext4|fuse.mergerfs",mountpoint!="/home/user/media"} * 100', "{{mountpoint}}")],
      w=8, h=9, mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 75), (BAD, 90)))
s.ts("Utilización de cada disco", [(f'rate(node_disk_io_time_seconds_total{{{DISK}}}[{RI}]) * 100', "{{device}}")],
     w=8, h=9, unit="percent", maxv=100, thr=th((GOOD, None), (BAD, 90)), thr_style="dashed")
s.ts("Temperatura de discos", [(f'{SMART}{{name="temperature_celsius"}}', "{{device}}")], w=8, h=9, unit="celsius", minv=20,
     thr=th((GOOD, None), (WARN, 50), (BAD, 60)), thr_style="dashed")
s.ts("Lectura por disco", [(f'rate(node_disk_read_bytes_total{{{DISK}}}[{RI}])', "{{device}}")], w=8, unit="Bps")
s.ts("Escritura por disco", [(f'rate(node_disk_written_bytes_total{{{DISK}}}[{RI}])', "{{device}}")], w=8, unit="Bps")
s.ts("Presión PSI", [(f'rate(node_pressure_io_stalled_seconds_total[{RI}]) * 100', "I/O detenido"),
                     (f'rate(node_pressure_cpu_waiting_seconds_total[{RI}]) * 100', "CPU esperando"),
                     (f'rate(node_pressure_memory_stalled_seconds_total[{RI}]) * 100', "Memoria detenida")],
     w=8, unit="percent", overrides=[by_name("I/O detenido", color_of(BAD)), by_name("CPU esperando", color_of(INFO)), by_name("Memoria detenida", color_of(VIOLET))])

s.section("Salud SMART por disco")
s.bar("Sectores pendientes", [(f'{SMART}{{name="current_pending_sector"}}', "{{device}}")], w=6, h=7, mode="lcd", decimals=0, minv=0, maxv=10,
      thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
s.bar("Sectores reubicados", [(f'{SMART}{{name="reallocated_sector_ct"}}', "{{device}}")], w=6, h=7, mode="lcd", decimals=0, minv=0, maxv=10,
      thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
s.bar("Errores CRC acumulados", [(f'{SMART}{{name="udma_crc_error_count"}}', "{{device}}")], w=6, h=7, mode="gradient", decimals=0, minv=0,
      thr=th((GOOD, None), (WARN, 1), (BAD, 5000)), desc="Contador de por vida: sdb y sdd tienen historial. Lo que importa es que no crezca (ver 'CRC nuevos').")
s.bar("Horas de uso", [(f'{SMART}{{name="power_on_hours"}}', "{{device}}")], w=6, h=7, mode="gradient", unit="h", decimals=0, color=VIOLET, minv=0)

s.section("Mantenimiento del host")
s.stat("Actualizaciones pendientes", ["sum(lab_pending_updates)"], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 25)), desc="apt, snap y flatpak.")
s.stat("De seguridad pendientes", ["sum(lab_pending_security_updates)"], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
s.stat("Reinicio requerido", ["max(lab_reboot_required)"], w=4, spark=False, thr=th((GOOD, None), (WARN, 1)),
       mappings=val_map({"0": ("No", GOOD), "1": ("Sí", WARN)}), mode="background")
s.stat("Units systemd fallidas", ["sum(lab_systemd_failed_units)"], w=4, thr=th((GOOD, None), (BAD, 1)))
s.stat("Última actualización (updn)", ["time() - max(lab_updn_last_success_timestamp_seconds)"], w=4, unit="s", decimals=1,
       thr=th((GOOD, None), (WARN, 172800), (BAD, 604800)), desc="Tiempo desde la última corrida exitosa de updn.")
s.stat("Edad de las métricas del host", ["time() - max(lab_host_metrics_timestamp_seconds)"], w=4, unit="s", decimals=0,
       thr=th((GOOD, None), (WARN, 600), (BAD, 1800)), desc="Si pasa de 10 min, el timer lab-host-metrics dejó de correr.")
s.save(os.path.join(OUT, "servidor-discos.json"))

# =====================================================================
#  2) Docker y LocalStack
# =====================================================================
d = Board("Docker y LocalStack", "docker-localstack", ["sparky", "docker"],
          desc="Contenedores Docker del host y servicios de LocalStack.")
d.section("Estado")
d.stat("Docker", ["lab_docker_up"], w=4, spark=False, thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
d.stat("LocalStack", ["lab_localstack_up"], w=4, spark=False, thr=th((BAD, None), (GOOD, 1)), mappings=UP_DOWN, mode="background")
d.stat("Servicios activos", ["sum(lab_localstack_service_running)"], w=4, color=INFO, spark=False)
d.stat("Servicios reportados", ["count(lab_localstack_service_running)"], w=4, color=SLATE, spark=False)
d.stat("Contenedores corriendo", ["sum(lab_docker_container_running)"], w=4, color=INFO, spark=False)
d.stat("Edad de las métricas", ["time() - max(lab_host_metrics_timestamp_seconds)"], w=4, unit="s", decimals=0, thr=th((GOOD, None), (WARN, 600), (BAD, 1800)))
d.section("Consumo de los contenedores")
d.ts("CPU por contenedor", [("lab_docker_container_cpu_percent", "{{name}}")], unit="percent", legend="table")
d.ts("Memoria por contenedor", [("lab_docker_container_memory_bytes", "{{name}}")], unit="bytes", legend="table")
d.section("Servicios de LocalStack")
d.timeline("Disponibilidad por servicio", [("lab_localstack_service_running", "{{service}}")], w=24, h=14,
           mappings=val_map({"0": ("no", BAD), "1": ("sí", GOOD)}))
d.save(os.path.join(OUT, "docker-localstack.json"))

# =====================================================================
#  3) Plataforma: Traefik, ArgoCD, cert-manager, Velero, MinIO
# =====================================================================
p = Board("Plataforma", "plataforma", ["sparky", "plataforma"],
          desc="Traefik, ArgoCD, cert-manager, Velero y MinIO.")
p.section("Traefik")
p.stat("Peticiones por segundo", [f"sum(rate(traefik_service_requests_total[{RI}]))"], w=4, unit="reqps", decimals=2, color=INFO)
p.stat("Errores 5xx", [f'(sum(rate(traefik_service_requests_total{{code=~"5.."}}[{RI}])) or vector(0)) / sum(rate(traefik_service_requests_total[{RI}])) * 100'],
       w=4, unit="percent", decimals=2, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
p.stat("Tráfico cifrado (TLS)", [f"sum(rate(traefik_entrypoint_requests_tls_total[{RI}])) / sum(rate(traefik_entrypoint_requests_total[{RI}])) * 100"],
       w=4, unit="percent", decimals=0, color=VIOLET)
p.stat("Conexiones abiertas", ["sum(traefik_open_connections)"], w=4, color=INFO)
p.stat("Salida de datos", [f"sum(rate(traefik_entrypoint_responses_bytes_total[{RI}]))"], w=4, unit="Bps", color=PINK)
p.stat("Última recarga de config", ["min(traefik_config_last_reload_success)"], w=4, spark=False, thr=th((BAD, None), (GOOD, 1)),
       mappings=val_map({"0": ("FALLÓ", BAD), "1": ("OK", GOOD)}), mode="background")
p.ts("Peticiones por clase HTTP", HTTP_CLASSES, w=8, stack=True, fill=40, unit="reqps", overrides=CLASS_COLORS)
p.ts("Latencia de los servicios",
     [(f"histogram_quantile(0.50, sum by (le) (rate(traefik_service_request_duration_seconds_bucket[{RI}])))", "p50"),
      (f"histogram_quantile(0.95, sum by (le) (rate(traefik_service_request_duration_seconds_bucket[{RI}])))", "p95"),
      (f"histogram_quantile(0.99, sum by (le) (rate(traefik_service_request_duration_seconds_bucket[{RI}])))", "p99")],
     w=8, unit="s", fill=12, overrides=[by_name("p50", color_of(GOOD)), by_name("p95", color_of(WARN)), by_name("p99", color_of(BAD))])
p.ts("Peticiones por entrypoint", [(f"sum by (entrypoint) (rate(traefik_entrypoint_requests_total[{RI}]))", "{{entrypoint}}")], w=8, stack=True, fill=35, unit="reqps")
p.bar("Servicios más usados", [(f"sort_desc(topk(10, sum by (service) (rate(traefik_service_requests_total[{RI}]))))", "{{service}}")],
      w=12, h=9, mode="gradient", unit="reqps", decimals=3, color=VIOLET, minv=0, no_value="Sin tráfico")
p.bar("Servicios con errores 4xx/5xx", [(f'sort_desc(topk(10, sum by (service) (rate(traefik_service_requests_total{{code=~"4..|5.."}}[{RI}]))))', "{{service}}")],
      w=12, h=9, mode="gradient", unit="reqps", decimals=3, thr=th((GOOD, None), (WARN, 0.01), (BAD, 0.5)), minv=0, no_value="Sin errores")

p.section("ArgoCD")
p.stat("Apps sanas", ['sum(argocd_app_info{health_status="Healthy"}) / count(argocd_app_info) * 100'], w=8, unit="percent", decimals=0, thr=PCT_HEALTH)
p.stat("Apps fuera de sync", ['count(argocd_app_info{sync_status!="Synced"}) or vector(0)'], w=8, thr=th((GOOD, None), (WARN, 1)))
p.stat("Conexión al cluster", ["min(argocd_cluster_connection_status)"], w=8, spark=False, thr=th((BAD, None), (GOOD, 1)),
       mappings=val_map({"0": ("CAÍDA", BAD), "1": ("OK", GOOD)}), mode="background")
p.table("Aplicaciones", [("argocd_app_info", "")], w=12, h=7,
        transforms=[{"id": "filterFieldsByName", "options": {"include": {"names": ["name", "dest_namespace", "sync_status", "health_status"]}}},
                    {"id": "organize", "options": {"renameByName": {"name": "Aplicación", "dest_namespace": "Namespace", "sync_status": "Sync", "health_status": "Salud"},
                                                   "indexByName": {"name": 0, "dest_namespace": 1, "sync_status": 2, "health_status": 3}}}],
        overrides=[by_name("Salud", prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}), prop("custom.align", "center"),
                           prop("mappings", val_map({"Healthy": ("Healthy", GOOD), "Progressing": ("Progressing", BLUE), "Degraded": ("Degraded", BAD),
                                                     "Missing": ("Missing", WARN), "Suspended": ("Suspended", SLATE), "Unknown": ("Unknown", SLATE)}))),
                   by_name("Sync", prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}), prop("custom.align", "center"),
                           prop("mappings", val_map({"Synced": ("Synced", GOOD), "OutOfSync": ("OutOfSync", WARN), "Unknown": ("Unknown", SLATE)})))])
p.ts("Sincronizaciones por resultado", [(f"sum by (phase) (increase(argocd_app_sync_total[{RI}]))", "{{phase}}")], w=12, h=7, bars=True, stack=True, fill=70,
     overrides=[by_name("Succeeded", color_of(GOOD)), by_name("Failed", color_of(BAD)), by_name("Error", color_of(BAD)), by_name("Running", color_of(BLUE))])

p.section("cert-manager")
p.stat("Certificados listos", ['sum(certmanager_certificate_ready_status{condition="True"}) / count(count by (name, namespace) (certmanager_certificate_ready_status)) * 100'],
       w=8, unit="percent", decimals=0, thr=PCT_HEALTH)
p.stat("ClusterIssuers listos", ['min(certmanager_clusterissuer_ready_status{condition="True"})'], w=8, spark=False, thr=th((BAD, None), (GOOD, 1)),
       mappings=val_map({"0": ("NO", BAD), "1": ("OK", GOOD)}), mode="background")
p.stat("Errores de sync (1 h)", ["sum(increase(certmanager_controller_sync_error_count_total[1h])) or vector(0)"], w=8, thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
p.bar("Días para vencer", [("sort((certmanager_certificate_expiration_timestamp_seconds - time()) / 86400)", "{{namespace}}/{{name}}")],
      w=12, h=7, mode="lcd", unit="d", decimals=0, minv=0, maxv=90, thr=th((BAD, None), (WARN, 14), (GOOD, 30)))
p.ts("Peticiones ACME (Let's Encrypt)", [(f"sum by (status) (rate(certmanager_http_acme_client_request_count_total[{RI}]))", "{{status}}")], w=12, h=7, stack=True, fill=35,
     overrides=CODE_COLORS)

p.section("Velero (backups)")
p.stat("Último backup", ["time() - max(velero_backup_last_successful_timestamp)"], w=4, unit="s", decimals=1, thr=th((GOOD, None), (WARN, 129600), (BAD, 172800)),
       desc="Verde: menos de 36 h.")
p.stat("Exitosos", ["sum(velero_backup_success_total) or vector(0)"], w=4, color=INFO)
p.stat("Con fallos", ["sum(velero_backup_failure_total) or vector(0)"], w=4, thr=th((GOOD, None), (BAD, 1)))
p.stat("Parciales", ["sum(velero_backup_partial_failure_total) or vector(0)"], w=4, thr=th((GOOD, None), (WARN, 1)))
p.stat("Tamaño del último", ["max(velero_backup_tarball_size_bytes)"], w=4, unit="bytes", color=VIOLET)
p.stat("Ubicación de backup", ["min(velero_backup_location_status_gauge)"], w=4, spark=False, thr=th((BAD, None), (GOOD, 1)),
       mappings=val_map({"0": ("NO DISPONIBLE", BAD), "1": ("Disponible", GOOD)}), mode="background")
p.bar("Edad del último backup exitoso", [("sort_desc(time() - velero_backup_last_successful_timestamp)", "{{schedule}}")], w=8, h=7, mode="lcd", unit="s",
      decimals=1, minv=0, maxv=172800, thr=th((GOOD, None), (WARN, 129600), (BAD, 172800)))
p.ts("Tamaño de cada backup", [("velero_backup_tarball_size_bytes", "{{schedule}}")], w=8, h=7, unit="bytes")
p.ts("Objetos respaldados", [("velero_backup_items_total", "{{schedule}}")], w=8, h=7)

p.section("MinIO")
p.gauge("Capacidad usada", "max((1 - minio_cluster_capacity_usable_free_bytes / minio_cluster_capacity_usable_total_bytes) * 100)", w=6, thr=th((GOOD, None), (WARN, 75), (BAD, 90)))
p.stat("Objetos totales", ["sum(minio_bucket_usage_object_total)"], w=6, h=6, color=INFO)
p.stat("Discos online", ["min(minio_cluster_disk_online_total)"], w=6, h=6, color=GOOD, spark=False)
p.stat("Discos offline", ["max(minio_cluster_disk_offline_total) or vector(0)"], w=6, h=6, thr=th((GOOD, None), (BAD, 1)), spark=False)
p.bar("Uso por bucket", [("sort_desc(max by (bucket) (minio_bucket_usage_total_bytes))", "{{bucket}}")], w=8, h=7, mode="gradient", unit="bytes", color=VIOLET, minv=0)
p.ts("Tráfico por bucket (entrada)", [(f"sum by (bucket) (rate(minio_bucket_traffic_received_bytes[{RI}]))", "{{bucket}}")], w=8, h=7, unit="Bps")
p.ts("Descriptores de archivo y goroutines", [("max(minio_node_file_descriptor_open_total)", "Descriptores abiertos"), ("max(minio_node_go_routine_total)", "Goroutines")], w=8, h=7)
p.save(os.path.join(OUT, "plataforma.json"))

# =====================================================================
#  4) Apps y media
# =====================================================================
NSA = 'namespace=~"$namespace"'
PODF = f'{NSA},pod=~"$pod"'
CT = f'{PODF},container!="",container!="POD"'
SVC_NOISE = 'service!~"api@internal|noop@internal|.*acme.*"'
a = Board("Apps y media", "apps-media", ["sparky", "apps"],
          variables=[variable_query("namespace", "Namespace", "label_values(kube_pod_info, namespace)", default=["media"]),
                     variable_query("pod", "Pod", 'label_values(kube_pod_info{namespace=~"$namespace"}, pod)')],
          desc="Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent y demás apps. Elegí namespace y pods arriba.")
a.section("Estado de las apps")
a.stat("Pods listos", [f'sum(kube_pod_status_ready{{{NSA},condition="true"}}) / count(kube_pod_info{{{NSA}}}) * 100'], w=4, unit="percent", decimals=0, thr=PCT_HEALTH)
a.stat("Reinicios (24 h)", [f'sum(increase(kube_pod_container_status_restarts_total{{{PODF}}}[24h])) or vector(0)'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 10)))
a.stat("CPU", [f'sum(rate(container_cpu_usage_seconds_total{{{CT}}}[{RI}]))'], w=4, unit="short", decimals=2, color=INFO)
a.stat("Memoria", [f'sum(container_memory_working_set_bytes{{{CT}}})'], w=4, unit="bytes", color=VIOLET)
a.stat("Red entrada", [f'sum(rate(container_network_receive_bytes_total{{{PODF}}}[{RI}]))'], w=4, unit="Bps", color=INFO)
a.stat("Red salida", [f'sum(rate(container_network_transmit_bytes_total{{{PODF}}}[{RI}]))'], w=4, unit="Bps", color=PINK)
a.section("Consumo por pod")
a.ts("CPU por pod (núcleos)", [(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{CT}}}[{RI}]))', "{{pod}}")], h=9, stack=True, fill=30, unit="short", decimals=3, legend="table")
a.ts("Memoria por pod", [(f'sum by (pod) (container_memory_working_set_bytes{{{CT}}})', "{{pod}}")], h=9, stack=True, fill=30, unit="bytes", legend="table")
a.ts("Recibido por pod", [(f'sum by (pod) (rate(container_network_receive_bytes_total{{{PODF}}}[{RI}]))', "{{pod}}")], unit="Bps", stack=True, fill=30)
a.ts("Enviado por pod", [(f'sum by (pod) (rate(container_network_transmit_bytes_total{{{PODF}}}[{RI}]))', "{{pod}}")], unit="Bps", stack=True, fill=30)
a.bar("Reinicios por pod (24 h)", [(f'sort_desc(sum by (pod) (increase(kube_pod_container_status_restarts_total{{{PODF}}}[24h])) > 0)', "{{pod}}")],
      w=12, h=6, mode="lcd", decimals=0, minv=0, thr=th((GOOD, None), (WARN, 1), (BAD, 10)), no_value="Sin reinicios")
a.bar("CPU throttling por pod", [(f'sort_desc(sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{{{CT}}}[{RI}])) / sum by (pod) (rate(container_cpu_cfs_periods_total{{{CT}}}[{RI}])) * 100)', "{{pod}}")],
      w=12, h=6, mode="gradient", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 10), (BAD, 30)), no_value="Sin throttling")
a.section("Tráfico web (Traefik)")
a.ts("Peticiones por servicio", [(f'sum by (service) (rate(traefik_service_requests_total{{{SVC_NOISE}}}[{RI}]))', "{{service}}")], h=9, stack=True, fill=30, unit="reqps", legend="table")
a.ts("Errores 4xx/5xx por servicio", [(f'sum by (service) (rate(traefik_service_requests_total{{{SVC_NOISE},code=~"4..|5.."}}[{RI}])) > 0', "{{service}}")], h=9, unit="reqps",
     legend="table", no_value="Sin errores")
a.bar("Ancho de banda de salida por servicio", [(f'sort_desc(topk(8, sum by (service) (rate(traefik_service_responses_bytes_total{{{SVC_NOISE}}}[{RI}]))))', "{{service}}")],
      w=12, h=7, mode="gradient", unit="Bps", color=PINK, minv=0, no_value="Sin tráfico")
a.ts("Latencia p95 por servicio", [(f'histogram_quantile(0.95, sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket{{{SVC_NOISE}}}[{RI}])))', "{{service}}")],
     w=12, h=7, unit="s")
a.section("Almacenamiento de media")
a.bar("Uso de los discos de media", [('100 - node_filesystem_avail_bytes{mountpoint=~"/mnt/(media[0-9]|unified-media)"} / node_filesystem_size_bytes{mountpoint=~"/mnt/(media[0-9]|unified-media)"} * 100', "{{mountpoint}}")],
      w=8, h=8, mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 80), (BAD, 92)))
a.bar("Espacio libre", [('node_filesystem_avail_bytes{mountpoint=~"/mnt/(media[0-9]|unified-media)"}', "{{mountpoint}}")],
      w=8, h=8, mode="gradient", unit="bytes", color=C["teal"], minv=0)
a.ts("Utilización de los discos de media", [(f'rate(node_disk_io_time_seconds_total{{device=~"sd[a-c]"}}[{RI}]) * 100', "{{device}}")], w=8, h=8, unit="percent", maxv=100)
a.save(os.path.join(OUT, "apps-media.json"))

# =====================================================================
#  5) Guacamole
# =====================================================================
NSG = 'namespace="guacamole"'
GSVC = 'service=~".*guacamole.*"'
g = Board("Guacamole", "guacamole", ["sparky", "guacamole"],
          desc="Acceso remoto: salud de los pods, certificado, tráfico, intentos bloqueados y backups de la base.")
g.section("Estado")
g.stat("Deployments disponibles", [f'sum(kube_deployment_status_replicas_available{{{NSG}}}) / sum(kube_deployment_spec_replicas{{{NSG}}}) * 100'],
       w=4, unit="percent", decimals=0, thr=PCT_HEALTH, desc="guacamole, guacd y postgres.")
g.stat("Reinicios (24 h)", [f'sum(increase(kube_pod_container_status_restarts_total{{{NSG}}}[24h])) or vector(0)'], w=4, thr=th((GOOD, None), (WARN, 1), (BAD, 5)))
g.stat("Certificado vence en", [f'min((certmanager_certificate_expiration_timestamp_seconds{{{NSG}}} - time()) / 86400)'], w=4, unit="d", decimals=0,
       thr=th((BAD, None), (WARN, 14), (GOOD, 30)))
g.stat("Peticiones web", [f'sum(rate(traefik_service_requests_total{{{GSVC}}}[{RI}]))'], w=4, unit="reqps", decimals=3, color=INFO)
g.stat("Respuestas 403 (1 h)", [f'sum(increase(traefik_service_requests_total{{{GSVC},code="403"}}[1h])) or vector(0)'], w=4, thr=th((GOOD, None), (WARN, 5), (BAD, 20)),
       desc="Guacamole suele responder 403 a un login incorrecto, y el filtro de red también devuelve 403. Una ráfaga de golpes puede ser un intento de fuerza bruta.")
g.stat("Último backup de la base", [f'time() - max(kube_cronjob_status_last_successful_time{{{NSG}}})'], w=4, unit="s", decimals=1, thr=th((GOOD, None), (WARN, 129600), (BAD, 259200)),
       desc="Tiempo desde el último pg_dump exitoso.")
g.section("Recursos")
g.ts("CPU por pod", [(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{NSG},container!="",container!="POD"}}[{RI}]))', "{{pod}}")], w=8, unit="short", decimals=3)
g.ts("Memoria por pod", [(f'sum by (pod) (container_memory_working_set_bytes{{{NSG},container!="",container!="POD"}})', "{{pod}}")], w=8, unit="bytes")
g.ts("Red por pod", [(f'sum by (pod) (rate(container_network_receive_bytes_total{{{NSG}}}[{RI}]))', "{{pod}} ↓"),
                     (f'sum by (pod) (rate(container_network_transmit_bytes_total{{{NSG}}}[{RI}]))', "{{pod}} ↑")], w=8, unit="Bps",
     overrides=[by_regex(".*↑", prop("custom.transform", "negative-Y"))])
g.section("Tráfico y seguridad")
g.ts("Peticiones por código", [(f'sum by (code) (rate(traefik_service_requests_total{{{GSVC}}}[{RI}]))', "{{code}}")], w=12, stack=True, fill=35, unit="reqps", overrides=CODE_COLORS)
g.ts("Latencia p95", [(f'histogram_quantile(0.95, sum by (le) (rate(traefik_service_request_duration_seconds_bucket{{{GSVC}}}[{RI}])))', "p95")], w=12, unit="s", color=VIOLET)
g.bar("Respuestas por código (última hora)", [(f'sort_desc(sum by (code) (increase(traefik_service_requests_total{{{GSVC}}}[1h])))', "{{code}}")],
      w=12, h=7, mode="gradient", decimals=0, minv=0, color=INFO, no_value="Sin tráfico")
g.ts("Respuestas 403 y 429 (bloqueos y límite de tasa)", [(f'sum(rate(traefik_service_requests_total{{{GSVC},code="403"}}[{RI}]))', "403"),
                                                           (f'sum(rate(traefik_service_requests_total{{{GSVC},code="429"}}[{RI}]))', "429")], w=12, h=7, unit="reqps",
     overrides=[by_name("403", color_of(WARN)), by_name("429", color_of(BAD))])
g.section("Base de datos y backups")
g.bar("Uso de los volúmenes", [(f'sort_desc(kubelet_volume_stats_used_bytes{{{NSG}}} / kubelet_volume_stats_capacity_bytes{{{NSG}}} * 100)', "{{persistentvolumeclaim}}")],
      w=8, h=7, mode="lcd", unit="percent", minv=0, maxv=100, thr=th((GOOD, None), (WARN, 75), (BAD, 90)), no_value="Sin datos de volúmenes")
g.ts("Memoria de postgres", [(f'sum(container_memory_working_set_bytes{{{NSG},pod=~"postgres.*",container!="",container!="POD"}})', "postgres")], w=8, h=7, unit="bytes", color=VIOLET)
g.stat("Último backup de Velero", ["time() - max(velero_backup_last_successful_timestamp)"], w=8, h=7, unit="s", decimals=1, thr=th((GOOD, None), (WARN, 129600), (BAD, 172800)))
g.save(os.path.join(OUT, "guacamole.json"))
print("ok")
