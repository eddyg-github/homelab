import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dashlib import Dash, steps, G, O, R

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dashboards-src")
RI = "$__rate_interval"

# ---------- 1) Servidor: CPU, memoria y red ----------
d = Dash("Servidor: CPU, memoria y red", "servidor-recursos", ["host"])
NCPU = "scalar(count(count by (cpu) (node_cpu_seconds_total)))"
NET = 'device!~"lo|veth.*|cni.*|flannel.*|docker.*|br-.*|wg.*"'
d.stat("CPU usada", [f'100 - avg(rate(node_cpu_seconds_total{{mode="idle"}}[{RI}])) * 100'], 0, 0, unit="percent",
       th=steps((G, None), (O, 70), (R, 90)), minv=0, maxv=100, decimals=0)
d.stat("Memoria usada", ["(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100"], 4, 0, unit="percent",
       th=steps((G, None), (O, 80), (R, 90)), decimals=0)
d.stat("Swap usada", ["node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes"], 8, 0, unit="bytes",
       th=steps((G, None), (O, 512 * 1024**2), (R, 2 * 1024**3)))
d.stat("Carga (1 min)", ["node_load1"], 12, 0, th=steps((G, None), (O, 4), (R, 8)),
       desc="El equipo tiene 4 núcleos: cerca de 4 = al límite.")
d.stat("Tiempo encendido", ["time() - node_boot_time_seconds"], 16, 0, unit="s", decimals=0)
d.stat("Procesos esperando CPU (PSI)", [f"rate(node_pressure_cpu_waiting_seconds_total[{RI}]) * 100"], 20, 0, unit="percent",
       th=steps((G, None), (O, 10), (R, 30)), decimals=1)
d.ts("CPU por modo (% del total)", [(f'sum by (mode) (rate(node_cpu_seconds_total{{mode!="idle"}}[{RI}])) / {NCPU} * 100', "{{mode}}")],
     0, 4, 12, 8, unit="percent", minv=0, maxv=100, stack=True)
d.ts("Carga del sistema", [("node_load1", "load 1m")], 12, 4, 12, 8, desc="Comparar con 4 núcleos.")
d.ts("Memoria", [("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "usada"),
                 ("node_memory_Cached_bytes + node_memory_Buffers_bytes", "caché y buffers"),
                 ("node_memory_MemFree_bytes", "libre"),
                 ("node_memory_MemTotal_bytes", "total")], 0, 12, 12, 8, unit="bytes", minv=0)
d.ts("Swap", [("node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes", "usada")], 12, 12, 12, 8, unit="bytes", minv=0)
d.ts("Red: recibido", [(f"rate(node_network_receive_bytes_total{{{NET}}}[{RI}])", "{{device}}")], 0, 20, 12, 8, unit="Bps")
d.ts("Red: enviado", [(f"rate(node_network_transmit_bytes_total{{{NET}}}[{RI}])", "{{device}}")], 12, 20, 12, 8, unit="Bps")
d.save(os.path.join(OUT, "servidor-recursos.json"))

# ---------- 2) k3s y pods ----------
d = Dash("k3s y pods", "k3s-pods", ["k3s"])
CTR = 'container!="",container!="POD"'
d.stat("Nodo Ready", ['sum(kube_node_status_condition{condition="Ready",status="true"})'], 0, 0, w=3,
       th=steps((R, None), (G, 1)), mappings=[{"type": "value", "options": {"0": {"text": "CAÍDO"}, "1": {"text": "OK"}}}])
d.stat("Pods Running", ['sum(kube_pod_status_phase{phase="Running"})'], 3, 0, w=3, th=steps((G, None)))
d.stat("Pods Pending", ['sum(kube_pod_status_phase{phase="Pending"}) or vector(0)'], 6, 0, w=3, th=steps((G, None), (O, 1)))
d.stat("Pods Failed/Unknown", ['sum(kube_pod_status_phase{phase=~"Failed|Unknown"}) or vector(0)'], 9, 0, w=3, th=steps((G, None), (R, 1)),
       desc="Un 0 acá es lo bueno. El dashboard viejo mostraba 'No data' porque contaba una lista vacía.")
d.stat("CrashLoopBackOff", ['sum(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}) or vector(0)'], 12, 0, w=3, th=steps((G, None), (R, 1)))
d.stat("Deployments incompletos", ["count((kube_deployment_spec_replicas - on(namespace, deployment) kube_deployment_status_replicas_available) > 0) or vector(0)"],
       15, 0, w=3, th=steps((G, None), (O, 1)))
d.stat("PVC con problemas", ['sum(kube_persistentvolumeclaim_status_phase{phase=~"Pending|Lost"}) or vector(0)'], 18, 0, w=3, th=steps((G, None), (R, 1)))
d.stat("Pods en kubelet", ["kubelet_running_pods"], 21, 0, w=3)
d.ts("CPU por namespace (núcleos)", [(f"sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CTR}}}[{RI}]))", "{{namespace}}")],
     0, 4, 12, 8, minv=0, stack=True, desc="Suma de núcleos usados. El equipo tiene 4.")
d.ts("Memoria por namespace", [(f"sum by (namespace) (container_memory_working_set_bytes{{{CTR}}})", "{{namespace}}")],
     12, 4, 12, 8, unit="bytes", minv=0, stack=True)
d.ts("Top 10 pods por CPU", [(f"topk(10, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{CTR}}}[{RI}])))", "{{namespace}}/{{pod}}")],
     0, 12, 12, 8, minv=0)
d.bar("Top 10 pods por memoria", [(f"topk(10, sum by (namespace, pod) (container_memory_working_set_bytes{{{CTR}}}))", "{{namespace}}/{{pod}}")],
      12, 12, 12, 8, unit="bytes", minv=0)
d.ts("Reinicios por pod (última hora)", [('sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0', "{{namespace}}/{{pod}}")],
     0, 20, 12, 8, minv=0, desc="Vacío = nada se reinició en la última hora.")
d.ts("Red por namespace", [(f"sum by (namespace) (rate(container_network_receive_bytes_total[{RI}]))", "{{namespace}} entrada"),
                           (f"sum by (namespace) (rate(container_network_transmit_bytes_total[{RI}]))", "{{namespace}} salida")],
     12, 20, 12, 8, unit="Bps")
d.ts("API server: peticiones por código", [(f"sum by (code) (rate(apiserver_request_total[{RI}]))", "{{code}}")], 0, 28, 12, 8, minv=0)
d.ts("API server: latencia p99", [(f'histogram_quantile(0.99, sum by (le) (rate(apiserver_request_duration_seconds_bucket{{verb!="WATCH"}}[{RI}])))', "p99")],
     12, 28, 12, 8, unit="s", minv=0)
d.save(os.path.join(OUT, "k3s-pods.json"))

# ---------- 3) Docker y LocalStack ----------
d = Dash("Docker y LocalStack", "docker-localstack", ["docker", "localstack"])
d.stat("Docker", ["lab_docker_up"], 0, 0, w=4, th=steps((R, None), (G, 1)),
       mappings=[{"type": "value", "options": {"0": {"text": "CAÍDO"}, "1": {"text": "OK"}}}])
d.stat("LocalStack", ["lab_localstack_up"], 4, 0, w=4, th=steps((R, None), (G, 1)),
       mappings=[{"type": "value", "options": {"0": {"text": "CAÍDO"}, "1": {"text": "OK"}}}])
d.stat("Contenedores corriendo", [("lab_docker_container_running", "{{name}}")], 8, 0, w=8, named=True, th=steps((R, None), (G, 1)),
       mappings=[{"type": "value", "options": {"0": {"text": "PARADO"}, "1": {"text": "corriendo"}}}])
d.stat("Servicios LocalStack activos", ["sum(lab_localstack_service_running)", "count(lab_localstack_service_running)"], 16, 0, w=4, th=steps((G, None)),
       desc="Primer número: activos. Segundo: total que reporta LocalStack.")
d.stat("Edad de las métricas del host", ["time() - lab_host_metrics_timestamp_seconds"], 20, 0, w=4, unit="s", decimals=0,
       th=steps((G, None), (O, 600), (R, 1800)), desc="Si pasa de 10 min, el timer lab-host-metrics dejó de correr.")
d.ts("CPU por contenedor (%)", [("lab_docker_container_cpu_percent", "{{name}}")], 0, 4, 12, 8, unit="percent", minv=0)
d.ts("Memoria por contenedor", [("lab_docker_container_memory_bytes", "{{name}}")], 12, 4, 12, 8, unit="bytes", minv=0)
d.stat("Servicios de LocalStack", [("lab_localstack_service_running", "{{service}}")], 0, 12, w=24, h=8, named=True,
       th=steps((R, None), (G, 1)), mappings=[{"type": "value", "options": {"0": {"text": "no"}, "1": {"text": "sí"}}}],
       desc="Verde = el servicio figura como disponible en LocalStack.")
d.save(os.path.join(OUT, "docker-localstack.json"))
print("ok")
