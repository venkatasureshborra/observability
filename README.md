# Production-Grade Observability Stack on Kubernetes

## Stack

| Component | Version | Role |
|---|---|---|
| **OpenTelemetry Collector** | otelcol-contrib 0.115.1 | Central telemetry gateway |
| **Prometheus** | 2.55.1 | Metrics storage & scraping |
| **Loki** | 3.3.2 | Log aggregation |
| **Tempo** | 2.7.1 | Distributed tracing |
| **MinIO** | RELEASE.2024-11-07 | S3-compatible object store |
| **Grafana** | 11.4.0 | Dashboards, alerts, exploration |
| **OTel Demo** | Helm 0.33.5 | Sample microservices app |

## Architecture

```
OTel Demo Microservices
        │  OTLP (gRPC :4317)
        ▼
OTel Collector (otelcol-contrib)
   ├── processors: batch, memory_limiter, k8sattributes, tail_sampling
   ├──► Prometheus  (remote_write → :9090)
   ├──► Loki        (OTLP logs   → :3100)
   └──► Tempo       (OTLP traces → :4317)
            │
            └──► MinIO S3
                   ├── bucket: loki-chunks
                   ├── bucket: loki-ruler
                   ├── bucket: loki-admin
                   └── bucket: tempo-traces

Grafana ◄── queries all three backends
```

## Quick Start

### Prerequisites
- Docker Desktop (or Docker Engine) running
- `kind` v0.26+
- `kubectl` v1.31+
- `helm` v3.16+

### Full Deploy (one command)

```bash
chmod +x scripts/deploy.sh scripts/teardown.sh
./scripts/deploy.sh full
```

This will:
1. Create a 3-node KinD cluster with port mappings
2. Deploy MinIO and create buckets
3. Deploy Prometheus, Loki, Tempo, OTel Collector, Grafana
4. Deploy the OTel Demo application via Helm
5. Run health checks and print access URLs

### Step-by-step (optional)

```bash
# 1. Create KinD cluster only
./scripts/deploy.sh cluster

# 2. Deploy the observability stack
./scripts/deploy.sh stack

# 3. Deploy OTel Demo app
./scripts/deploy.sh demo

# 4. Run health checks
./scripts/deploy.sh health
```

## Access

| Service | URL | Credentials |
|---|---|---|
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | — |
| MinIO Console | http://localhost:9001 | minio / minio123 |
| OTel Demo | (port-forward below) | — |

### Access OTel Demo frontend

```bash
kubectl port-forward -n otel-demo svc/otel-demo-frontend-proxy 8080:8080
# then open http://localhost:8080
```

## Grafana: Exploring Telemetry

### Metrics (PromQL)
Navigate to Explore → select Prometheus datasource:

```promql
# Request rate by service
rate(http_server_duration_milliseconds_count[5m])

# P95 latency
histogram_quantile(0.95, rate(http_server_duration_milliseconds_bucket[5m]))

# Error rate
rate(http_server_duration_milliseconds_count{http_status_code=~"5.."}[5m])
  / rate(http_server_duration_milliseconds_count[5m])
```

### Logs (LogQL)
Navigate to Explore → select Loki datasource:

```logql
# All logs from otel-demo namespace
{namespace="otel-demo"}

# Error logs only
{namespace="otel-demo"} |= "error" | logfmt

# Logs for a specific service
{namespace="otel-demo", app="frontend"} | json
```

### Traces
Navigate to Explore → select Tempo datasource:
- Use **Search** tab to find traces by service, duration, or status
- Click any trace to see the full waterfall
- Click **Logs for this span** to jump to correlated logs in Loki

### Trace ↔ Metric ↔ Log Correlation
This stack is wired for full correlation:
- Prometheus exemplars link metrics → traces (configure `--enable-feature=exemplar-storage` if needed)
- Loki derived fields extract `traceID` from logs → link to Tempo
- Tempo service graph generates RED metrics → link to Prometheus

## Key Design Decisions

**Why OTel Collector as gateway?**
All services push OTLP to one collector instead of directly to backends. The collector adds k8s metadata enrichment, tail-based sampling, and fan-out to all three backends in a single pipeline change.

**Why MinIO for both Loki and Tempo?**
Loki's TSDB schema (v13) and Tempo both use S3-compatible object storage. MinIO runs in-cluster providing real S3 semantics without cloud costs — identical to production AWS S3 usage.

**Why tail sampling in the collector?**
Head-based sampling (at the SDK) drops spans before you know if a trace has errors. Tail sampling waits for the full trace, keeping 100% of error traces and slow traces (>500ms) while sampling healthy fast traces at 10%.

**Loki schema v13 with TSDB**
TSDB is Loki's most efficient index store. Combined with the S3 object store backend, this mirrors Grafana Cloud Loki's architecture exactly.

**Tempo metrics-generator**
Tempo's metrics generator derives RED metrics (rate, error, duration) directly from trace spans and remote-writes them to Prometheus — no instrumentation changes needed in services.

## Useful Commands

```bash
# Watch all pods come up
kubectl get pods -n monitoring -w
kubectl get pods -n otel-demo -w

# Check OTel Collector pipelines (zpages)
kubectl port-forward -n monitoring deploy/otel-collector 55679:55679
# open http://localhost:55679/debug/tracez

# Check Loki ingestion
kubectl logs -n monitoring deploy/loki -f

# Check Tempo ingestion
kubectl logs -n monitoring deploy/tempo -f

# Check Prometheus targets
# open http://localhost:9090/targets

# Reload Prometheus config without restart
kubectl exec -n monitoring deploy/prometheus -- \
  wget -qO- --post-data='' http://localhost:9090/-/reload

# MinIO bucket contents
kubectl exec -n monitoring deploy/minio -- \
  mc ls local/loki-chunks

# Resource usage
kubectl top pods -n monitoring
kubectl top pods -n otel-demo
```

## Teardown

```bash
./scripts/teardown.sh
```

## Resource Requirements

| Component | CPU Request | Mem Request | CPU Limit | Mem Limit |
|---|---|---|---|---|
| OTel Collector | 200m | 256Mi | 1000m | 1Gi |
| Prometheus | 200m | 512Mi | 1000m | 1Gi |
| Loki | 200m | 256Mi | 1000m | 1Gi |
| Tempo | 200m | 256Mi | 1000m | 1Gi |
| Grafana | 100m | 256Mi | 500m | 512Mi |
| MinIO | 100m | 256Mi | 500m | 512Mi |
| OTel Demo (total) | ~1200m | ~1.5Gi | ~2500m | ~3.5Gi |

Total fits comfortably in 4 CPU / 16 GB RAM.

## Troubleshooting

**Loki fails to start — bucket not found**
MinIO bucket job may not have completed. Re-run:
```bash
kubectl delete job minio-create-buckets -n monitoring
kubectl apply -f minio/minio.yaml
```

**OTel Collector CrashLoopBackOff**
Check logs: `kubectl logs -n monitoring deploy/otel-collector`
The k8sattributes processor requires the ClusterRole — ensure RBAC was applied.

**Tempo shows no traces**
Verify the OTel Demo OTLP endpoint points to `otel-collector.monitoring.svc.cluster.local:4317`.
Check collector logs for export errors.

**Grafana datasource "Bad Gateway"**
Services use DNS names (`loki`, `prometheus`, `tempo`) — these resolve only within the cluster. Grafana is deployed in the same namespace (`monitoring`) so they resolve correctly.
