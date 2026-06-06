#!/usr/bin/env bash
# Verifies all hosted/ Argo CD Application manifests.
#
# For each Application that wraps a Helm chart:
#   1. yamllint on the Application YAML itself
#   2. helm template <chart> --repo <url> --version <v> -f <values-tempfile>
#      piped to kubeconform -strict -summary
#
# For the git-path Applications (grafana-dashboards):
#   1. yamllint only (no chart to render)
#
# Argo CD Application CRD schema: fetched from the upstream CRD catalog via
# kubeconform's -schema-location flag pointing to the datreeio/CRDs-catalog.
#
# Usage: bash hosted/verify.sh
# Run from the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTED_DIR="$REPO_ROOT/hosted"

# ---------- tool checks ----------
for tool in yamllint helm kubeconform; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: $tool not found. Install via brew install $tool (yamllint/kubeconform) or the Helm project." >&2
    exit 1
  fi
done

echo "=== Tools ==="
yamllint --version
helm version --short
kubeconform -v
echo ""

PASS=0; FAIL=0
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Argo CD CRD schema location (datreeio CRDs-catalog — covers argoproj Application)
ARGOCD_SCHEMA="https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/argoproj.io/application_v1alpha1.json"
ARGOCD_SCHEMA_DIR="$TMPDIR_ROOT/schemas/argoproj.io"
mkdir -p "$ARGOCD_SCHEMA_DIR"
if curl -fsSL "$ARGOCD_SCHEMA" -o "$ARGOCD_SCHEMA_DIR/application_v1alpha1.json" 2>/dev/null; then
  SCHEMA_LOCATION="$TMPDIR_ROOT/schemas/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json"
  echo "Argo CD CRD schema: downloaded OK"
else
  echo "WARN: could not fetch Argo CD CRD schema; Application YAML structural check will be skipped"
  SCHEMA_LOCATION=""
fi
echo ""

# ---------- helpers ----------
run_yamllint() {
  local f="$1"
  echo -n "  yamllint $f ... "
  if yamllint -d '{extends: default, rules: {line-length: {max: 200}, truthy: disable, document-start: disable}}' "$f" 2>&1; then
    echo "  OK"
    return 0
  else
    echo "  FAIL"
    return 1
  fi
}

run_kubeconform_app() {
  local f="$1"
  echo -n "  kubeconform (Application CRD) $f ... "
  if [[ -n "$SCHEMA_LOCATION" ]]; then
    if kubeconform -strict -summary \
        -schema-location default \
        -schema-location "$SCHEMA_LOCATION" \
        "$f" 2>&1; then
      return 0
    else
      return 1
    fi
  else
    echo "  SKIPPED (no CRD schema)"
    return 0
  fi
}

helm_render_kubeconform() {
  local name="$1" repo="$2" chart="$3" version="$4" values_file="$5"
  echo -n "  helm template $chart@$version | kubeconform -strict ... "
  local out
  out="$(helm template "verify-$name" "$chart" \
    --repo "$repo" \
    --version "$version" \
    -f "$values_file" 2>&1)" || { echo "FAIL (helm template error)"; echo "$out"; return 1; }
  # Filter helm WARNING lines (e.g. "WARNING: This chart is deprecated") that appear
  # before the first YAML document separator and cause kubeconform "missing 'kind'" errors.
  local kc_out kc_exit=0
  kc_out="$(echo "$out" | grep -v "^WARNING:" | kubeconform -strict -summary -output pretty 2>&1)" || kc_exit=$?
  echo "$kc_out"
  # Failure: a non-zero kubeconform exit, OR any non-zero Invalid/Errors count
  # ([1-9][0-9]* so counts >= 10 are caught too — a bare [1-9] missed "Invalid: 10").
  if [[ $kc_exit -ne 0 ]] || echo "$kc_out" | grep -qE "Invalid: [1-9][0-9]*|Errors: [1-9][0-9]*"; then
    echo "  FAIL"
    return 1
  fi
  echo "  OK"
  return 0
}

check() {
  local name="$1"; shift
  local ok=0
  echo "--- $name ---"
  "$@" && ok=1 || ok=0
  if [[ $ok -eq 1 ]]; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); fi
  echo ""
}

# ---------- per-file verification ----------

# ---- victoria-metrics (cluster — multitenant, #186) ----
VM_VALUES="$TMPDIR_ROOT/vm-values.yaml"
cat > "$VM_VALUES" <<'EOF'
vminsert:
  fullnameOverride: vminsert
  replicaCount: 1
  extraArgs:
    enableMultitenancyViaHeaders: "true"
vmselect:
  fullnameOverride: vmselect
  replicaCount: 1
  extraArgs:
    enableMultitenancyViaHeaders: "true"
vmstorage:
  fullnameOverride: vmstorage
  replicaCount: 1
  retentionPeriod: "30d"
  persistentVolume:
    enabled: true
    size: 20Gi
EOF
check "victoria-metrics yamllint"   run_yamllint "$HOSTED_DIR/victoria-metrics.yaml"
check "victoria-metrics argoapp"    run_kubeconform_app "$HOSTED_DIR/victoria-metrics.yaml"
check "victoria-metrics helm+kc"    helm_render_kubeconform \
  "vm" "https://victoriametrics.github.io/helm-charts/" \
  "victoria-metrics-cluster" "0.43.0" "$VM_VALUES"

# ---- victoria-logs ----
VL_VALUES="$TMPDIR_ROOT/vl-values.yaml"
cat > "$VL_VALUES" <<'EOF'
server:
  fullnameOverride: victorialogs
  retentionPeriod: "30d"
  persistentVolume:
    enabled: true
    size: 20Gi
  extraArgs:
    envflag.enable: "true"
    envflag.prefix: VM_
    loggerFormat: json
    http.shutdownDelay: 15s
EOF
check "victoria-logs yamllint"   run_yamllint "$HOSTED_DIR/victoria-logs.yaml"
check "victoria-logs argoapp"    run_kubeconform_app "$HOSTED_DIR/victoria-logs.yaml"
check "victoria-logs helm+kc"    helm_render_kubeconform \
  "vl" "https://victoriametrics.github.io/helm-charts/" \
  "victoria-logs-single" "0.13.6" "$VL_VALUES"

# ---- tempo ----
TEMPO_VALUES="$TMPDIR_ROOT/tempo-values.yaml"
cat > "$TEMPO_VALUES" <<'EOF'
fullnameOverride: tempo
persistence:
  enabled: true
  size: 20Gi
tempo:
  multitenancyEnabled: true
  retention: 720h
  storage:
    trace:
      backend: local
      local:
        path: /var/tempo/traces
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  metricsGenerator:
    enabled: false
EOF
check "tempo yamllint"   run_yamllint "$HOSTED_DIR/tempo.yaml"
check "tempo argoapp"    run_kubeconform_app "$HOSTED_DIR/tempo.yaml"
check "tempo helm+kc"    helm_render_kubeconform \
  "tempo" "https://grafana.github.io/helm-charts" \
  "tempo" "1.24.4" "$TEMPO_VALUES"

# ---- alloy ----
ALLOY_VALUES="$TMPDIR_ROOT/alloy-values.yaml"
cat > "$ALLOY_VALUES" <<'EOF'
controller:
  type: deployment
  replicas: 1
alloy:
  stabilityLevel: experimental
  extraPorts:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
  configMap:
    content: |
      logging { level = "info" format = "logfmt" }
EOF
check "alloy yamllint"   run_yamllint "$HOSTED_DIR/alloy.yaml"
check "alloy argoapp"    run_kubeconform_app "$HOSTED_DIR/alloy.yaml"
check "alloy helm+kc"    helm_render_kubeconform \
  "alloy" "https://grafana.github.io/helm-charts" \
  "alloy" "1.8.2" "$ALLOY_VALUES"

# ---- grafana ----
GRAFANA_VALUES="$TMPDIR_ROOT/grafana-values.yaml"
cat > "$GRAFANA_VALUES" <<'EOF'
fullnameOverride: grafana
admin:
  existingSecret: grafana-admin
  userKey: admin-user
  passwordKey: admin-password
grafana.ini:
  server:
    root_url: https://grafana.ops.oracle-apps.origoss.com
  auth.anonymous:
    enabled: false
  auth.generic_oauth:
    enabled: true
    name: Keycloak
    scopes: "openid email profile"
    auth_url: https://auth.oracle-apps.origoss.com/realms/agentregistry/protocol/openid-connect/auth
    token_url: https://auth.oracle-apps.origoss.com/realms/agentregistry/protocol/openid-connect/token
    api_url: https://auth.oracle-apps.origoss.com/realms/agentregistry/protocol/openid-connect/userinfo
    email_attribute_path: email
    role_attribute_path: "contains(['replace-me@origoss.invalid'], email) && 'Admin' || 'Viewer'"
    allow_sign_up: true
envValueFrom:
  GF_AUTH_GENERIC_OAUTH_CLIENT_ID:
    secretKeyRef:
      name: grafana-oidc
      key: client-id
  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
    secretKeyRef:
      name: grafana-oidc
      key: client-secret
# ingress.enabled: true here (manifest keeps it false until DNS) so the render
# exercises the Ingress template.
ingress:
  enabled: true
  ingressClassName: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - grafana.ops.oracle-apps.origoss.com
  tls:
    - secretName: grafana-tls
      hosts:
        - grafana.ops.oracle-apps.origoss.com
plugins:
  - victoriametrics-metrics-datasource
  - victoriametrics-logs-datasource
persistence:
  enabled: false
service:
  type: ClusterIP
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    searchNamespace: ALL
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: VictoriaMetrics
        uid: vmetrics
        type: victoriametrics-metrics-datasource
        access: proxy
        url: http://agentgateway-obs-read.agentgateway-obs-read.svc.cluster.local:8481/select/prometheus
        isDefault: true
        jsonData:
          oauthPassThru: true
      - name: VictoriaMetrics (Admin — all tenants)
        uid: vmetrics-admin
        type: victoriametrics-metrics-datasource
        access: proxy
        url: http://agentgateway-obs-read.agentgateway-obs-read.svc.cluster.local:8481/select/multitenant/prometheus
        jsonData:
          oauthPassThru: true
      - name: VictoriaLogs
        uid: vlogs
        type: victoriametrics-logs-datasource
        access: proxy
        url: http://agentgateway-obs-read.agentgateway-obs-read.svc.cluster.local:9428
        jsonData:
          oauthPassThru: true
      - name: Tempo
        uid: tempo
        type: tempo
        access: proxy
        url: http://agentgateway-obs-read.agentgateway-obs-read.svc.cluster.local:3200
        jsonData:
          oauthPassThru: true
          streamingEnabled: false
          tracesToLogsV2:
            datasourceUid: vlogs
            filterByTraceID: true
            spanStartTimeShift: "-1h"
            spanEndTimeShift: "1h"
          tracesToMetrics:
            datasourceUid: vmetrics
          serviceMap:
            datasourceUid: vmetrics
EOF
check "grafana yamllint"   run_yamllint "$HOSTED_DIR/grafana.yaml"
check "grafana argoapp"    run_kubeconform_app "$HOSTED_DIR/grafana.yaml"
check "grafana helm+kc"    helm_render_kubeconform \
  "grafana" "https://grafana.github.io/helm-charts" \
  "grafana" "10.5.15" "$GRAFANA_VALUES"

# ---- grafana-dashboards (git-path, no chart) ----
check "grafana-dashboards yamllint"  run_yamllint "$HOSTED_DIR/grafana-dashboards.yaml"
check "grafana-dashboards argoapp"   run_kubeconform_app "$HOSTED_DIR/grafana-dashboards.yaml"

# ---------- summary ----------
echo "=============================="
echo "PASSED: $PASS  FAILED: $FAIL"
echo "=============================="
[[ $FAIL -eq 0 ]]
