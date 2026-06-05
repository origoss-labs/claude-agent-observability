# Claude Agent Observability

A local Kubernetes platform that collects **traces, metrics, and logs** from
[Claude Code](https://code.claude.com) sessions and visualises them in Grafana.
v1 runs on a single-machine **kind** cluster.

See [CONTEXT.md](./CONTEXT.md) for the glossary and [docs/adr/](./docs/adr/) for
the decisions behind the component choices and the GitOps approach.

## Architecture

```
 Laptop (same machine)                kind cluster (single node)
 ┌────────────────────┐               ┌──────────────────────────────────────┐
 │ claude (CLI)        │   OTLP gRPC   │  Alloy (OTLP gateway :4317/:4318)      │
 │  telemetry on       │──:4317───────▶│    ├─ traces  ─────────▶ Tempo  (fs/PVC)│
 │  beta traces on     │ via kind      │    ├─ logs    ─────────▶ Loki   (fs/PVC)│
 │  content flags on   │ extraPortMaps │    └─ metrics ─remote_write▶ VictoriaMetrics (PVC)
 └────────────────────┘               │                                        │
                                       │  Grafana (:3000) ◀─ datasources + dashboards
                                       │  Argo CD ◀─ app-of-apps ◀─ GitHub repo  │
                                       └──────────────────────────────────────┘
```

| Signal  | Store           | Ingest | Viz     |
|---------|-----------------|--------|---------|
| Traces  | Grafana Tempo   | Alloy  | Grafana |
| Logs    | Grafana Loki    | Alloy  | Grafana |
| Metrics | VictoriaMetrics | Alloy  | Grafana |

Deployed via **Argo CD** (app-of-apps) syncing from this Git remote.

## Prerequisites

- [Podman](https://podman.io/) with a running `podman machine`, [kind](https://kind.sigs.k8s.io/), `kubectl`, `make`
  (the Makefile sets `KIND_EXPERIMENTAL_PROVIDER=podman`; for plain docker, unset it)
- Internet access (Argo CD pulls charts; reconciles from the GitHub remote)
- **This repo pushed to its remote.** Argo CD syncs from Git, *not* your working
  copy — commit and push before `make up`, and make sure the `repoURL` in
  `bootstrap/argocd/root-app.yaml`, `apps/networking.yaml`, and
  `apps/grafana-dashboards.yaml` matches your remote.

## Quick start

```bash
make up          # kind cluster + Argo CD + root app-of-apps
make status      # watch the Applications go Healthy/Synced
```

Then open Grafana at **http://localhost:3000** (`admin` / `admin`).

### Configure Claude Code to emit telemetry

The platform collects data only from `claude` sessions that have telemetry
enabled. This config is machine-wide (you run `claude` from your other
projects, not from here), so export these before launching `claude` — e.g. in
your shell profile or a per-session env:

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1   # enables traces (beta)
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_LOG_USER_PROMPTS=1                 # capture prompt text
export OTEL_LOG_TOOL_CONTENT=1                 # capture tool input/output
export OTEL_METRIC_EXPORT_INTERVAL=10000       # 10s, faster feedback while testing
```

Run `claude`, do some work, then check Grafana Explore (Tempo for the trace
waterfall, Loki for prompts/events, VictoriaMetrics for token/cost metrics).

### Argo CD UI (optional)

```bash
make password                                  # admin password
kubectl port-forward -n argocd svc/argocd-server 8080:443
# https://localhost:8080  (user: admin)
```

## Repo layout

```
CONTEXT.md                     glossary / ubiquitous language
docs/adr/                      architecture decision records
Makefile                       make up / down / status / password
kind/cluster.yaml              cluster + extraPortMappings (4317/4318/3000)
bootstrap/argocd/root-app.yaml the app-of-apps root Application
apps/*.yaml                    one Argo Application per component
manifests/networking/          Alloy OTLP NodePort Service
manifests/dashboards/          Grafana dashboard ConfigMaps (sidecar-loaded)
```

## Known verifications (first sync)

These were flagged during design and need a check the first time the stack comes
up — they depend on exact chart rendering:

- **Service DNS names** — Alloy/Grafana assume `victoriametrics-server`, `loki`,
  `tempo` in `observability`. Confirm against `kubectl get svc -n observability`
  and fix the URLs if a chart names them differently.
- **Alloy NodePort selector** — `manifests/networking/alloy-otlp-nodeport.yaml`
  selects `app.kubernetes.io/instance: alloy`. Confirm the chart's pod labels.
- **Metric naming** — confirm the normalised names VM stored (Explore) and adapt
  the dashboard PromQL accordingly. See the dashboard ConfigMap header.
- **Chart versions** — every Application uses `targetRevision: "*"`. Pin before
  using beyond local v1.
- **Dashboard bundle** — the starter board is a placeholder; adopt + adapt the
  ColeMurray/claude-code-otel JSON (instructions in the ConfigMap).
