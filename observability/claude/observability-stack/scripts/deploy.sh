#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Observability Stack - Full Deploy Script
# Prometheus + Grafana + Loki + Tempo + MinIO + OTel Collector
# Target: KinD cluster (4 CPU, 16 GB RAM)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Prerequisites check ──────────────────────────────────────────
check_prereqs() {
  info "Checking prerequisites..."
  local missing=()
  for cmd in kubectl helm kind; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing tools: ${missing[*]}"
    error "Install guide:"
    error "  kind:    https://kind.sigs.k8s.io/docs/user/quick-start/"
    error "  kubectl: https://kubernetes.io/docs/tasks/tools/"
    error "  helm:    https://helm.sh/docs/intro/install/"
    exit 1
  fi
  success "All prerequisites found"
}

# ── KinD cluster ─────────────────────────────────────────────────
create_kind_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^observability$"; then
    warn "KinD cluster 'observability' already exists, skipping creation"
    return 0
  fi

  info "Creating KinD cluster 'observability'..."
  cat <<EOF | kind create cluster --name observability --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30300   # Prometheus NodePort
        hostPort: 9090
        protocol: TCP
      - containerPort: 30000   # Grafana NodePort
        hostPort: 3000
        protocol: TCP
      - containerPort: 30100   # Loki NodePort
        hostPort: 3100
        protocol: TCP
      - containerPort: 30200   # Tempo NodePort
        hostPort: 3200
        protocol: TCP
      - containerPort: 31317   # OTel gRPC NodePort
        hostPort: 4317
        protocol: TCP
      - containerPort: 31318   # OTel HTTP NodePort
        hostPort: 4318
        protocol: TCP
      - containerPort: 30900   # MinIO API NodePort
        hostPort: 9000
        protocol: TCP
      - containerPort: 30901   # MinIO Console NodePort
        hostPort: 9001
        protocol: TCP
  - role: worker
  - role: worker
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        "feature-gates": "EphemeralContainers=true"
EOF
  success "KinD cluster created"
}

# ── Patch services to NodePort for KinD port-forwarding ──────────
patch_nodeports() {
  info "Patching services to NodePort for KinD..."

  # Grafana NodePort 30000
  kubectl patch svc grafana -n monitoring \
    -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":3000,"targetPort":3000,"nodePort":30000}]}}' \
    --ignore-not-found || true

  # Prometheus NodePort 30300
  kubectl patch svc prometheus -n monitoring \
    -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":9090,"targetPort":9090,"nodePort":30300}]}}' \
    --ignore-not-found || true

  # MinIO Console NodePort 30901
  kubectl patch svc minio -n monitoring \
    -p '{"spec":{"type":"NodePort","ports":[{"name":"api","port":9000,"targetPort":9000,"nodePort":30900},{"name":"console","port":9001,"targetPort":9001,"nodePort":30901}]}}' \
    --ignore-not-found || true

  success "NodePort patches applied"
}

# ── Wait for pod readiness ────────────────────────────────────────
wait_for_deployment() {
  local name="$1"
  local namespace="${2:-monitoring}"
  local timeout="${3:-300}"
  info "Waiting for deployment/$name in namespace $namespace (timeout: ${timeout}s)..."
  kubectl rollout status deployment/"$name" \
    -n "$namespace" \
    --timeout="${timeout}s"
  success "$name is ready"
}

# ── Apply manifests ───────────────────────────────────────────────
deploy_stack() {
  info "Deploying Observability Stack..."

  # 1. Namespaces first
  kubectl apply -f "${SCRIPT_DIR}/namespace/namespace.yaml"
  sleep 2

  # 2. MinIO (storage must come up before Loki/Tempo)
  info "Deploying MinIO..."
  kubectl apply -f "${SCRIPT_DIR}/minio/minio.yaml"
  wait_for_deployment minio monitoring 240

  # 3. Create MinIO buckets
  info "Creating MinIO buckets..."
  kubectl wait --for=condition=complete job/minio-create-buckets \
    -n monitoring --timeout=120s || {
    warn "Bucket job not complete yet, checking logs..."
    kubectl logs -n monitoring -l job-name=minio-create-buckets --tail=20 || true
  }

  # 4. Prometheus
  info "Deploying Prometheus..."
  kubectl apply -f "${SCRIPT_DIR}/prometheus/prometheus.yaml"
  wait_for_deployment prometheus monitoring 240

  # 5. Loki
  info "Deploying Loki..."
  kubectl apply -f "${SCRIPT_DIR}/loki/loki.yaml"
  wait_for_deployment loki monitoring 300

  # 6. Tempo
  info "Deploying Tempo..."
  kubectl apply -f "${SCRIPT_DIR}/tempo/tempo.yaml"
  wait_for_deployment tempo monitoring 300

  # 7. OTel Collector
  info "Deploying OTel Collector..."
  kubectl apply -f "${SCRIPT_DIR}/otel-collector/otel-collector.yaml"
  wait_for_deployment otel-collector monitoring 240

  # 8. Grafana
  info "Deploying Grafana..."
  kubectl apply -f "${SCRIPT_DIR}/grafana/grafana.yaml"
  wait_for_deployment grafana monitoring 240

  success "All core stack components deployed!"
}

# ── Deploy OTel Demo Application ──────────────────────────────────
deploy_otel_demo() {
  info "Adding OpenTelemetry Helm repo..."
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
  helm repo update

  info "Deploying OTel Demo application..."
  helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
    --namespace otel-demo \
    --create-namespace \
    --values "${SCRIPT_DIR}/otel-demo/otel-demo-values.yaml" \
    --version 0.33.5 \
    --timeout 10m \
    --wait

  success "OTel Demo deployed!"
}

# ── Health checks ─────────────────────────────────────────────────
run_health_checks() {
  info "Running health checks..."
  local failed=0

  check_endpoint() {
    local name="$1"
    local pod_label="$2"
    local namespace="${3:-monitoring}"
    local path="${4:-/}"
    local port="${5:-8080}"

    local pod
    pod=$(kubectl get pods -n "$namespace" -l "app=$pod_label" \
          --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod" ]]; then
      error "$name: no running pod found"
      ((failed++))
      return
    fi

    if kubectl exec -n "$namespace" "$pod" -- \
        wget -qO- --timeout=5 "http://localhost:${port}${path}" &>/dev/null; then
      success "$name health check passed (pod: $pod)"
    else
      error "$name health check FAILED"
      ((failed++))
    fi
  }

  check_endpoint "Prometheus"     "prometheus"     "monitoring" "/-/ready" "9090"
  check_endpoint "Loki"           "loki"           "monitoring" "/ready"   "3100"
  check_endpoint "Tempo"          "tempo"          "monitoring" "/ready"   "3200"
  check_endpoint "OTel Collector" "otel-collector" "monitoring" "/"        "13133"
  check_endpoint "Grafana"        "grafana"        "monitoring" "/api/health" "3000"

  if [[ $failed -eq 0 ]]; then
    success "All health checks passed!"
  else
    error "$failed health check(s) failed. Check logs with: kubectl logs -n monitoring <pod-name>"
  fi
}

# ── Print access info ─────────────────────────────────────────────
print_access_info() {
  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}        Observability Stack - Access Information           ${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${GREEN}Grafana${NC}         http://localhost:3000   (admin / admin)"
  echo -e "  ${GREEN}Prometheus${NC}      http://localhost:9090"
  echo -e "  ${GREEN}MinIO Console${NC}   http://localhost:9001   (minio / minio123)"
  echo -e "  ${GREEN}OTel Demo App${NC}   http://localhost:8080   (via port-forward)"
  echo ""
  echo -e "  ${YELLOW}Port-forward OTel Demo frontend:${NC}"
  echo -e "  kubectl port-forward -n otel-demo svc/otel-demo-frontend-proxy 8080:8080"
  echo ""
  echo -e "  ${YELLOW}Useful commands:${NC}"
  echo -e "  kubectl get pods -n monitoring"
  echo -e "  kubectl get pods -n otel-demo"
  echo -e "  kubectl logs -n monitoring deploy/otel-collector -f"
  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
}

# ── Main ──────────────────────────────────────────────────────────
main() {
  local cmd="${1:-full}"

  case "$cmd" in
    cluster)
      check_prereqs
      create_kind_cluster
      ;;
    stack)
      check_prereqs
      deploy_stack
      patch_nodeports
      run_health_checks
      print_access_info
      ;;
    demo)
      check_prereqs
      deploy_otel_demo
      ;;
    health)
      run_health_checks
      ;;
    full)
      check_prereqs
      create_kind_cluster
      deploy_stack
      patch_nodeports
      deploy_otel_demo
      run_health_checks
      print_access_info
      ;;
    *)
      echo "Usage: $0 [full|cluster|stack|demo|health]"
      echo "  full    - Create cluster + deploy everything (default)"
      echo "  cluster - Create KinD cluster only"
      echo "  stack   - Deploy monitoring stack only"
      echo "  demo    - Deploy OTel Demo app only"
      echo "  health  - Run health checks only"
      exit 1
      ;;
  esac
}

main "$@"
