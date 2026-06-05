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
export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative  # recommended; Alloy also converts delta->cumulative as a safety net
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

## Status of first-sync verifications

Resolved during bring-up against a live `claude -p` run:

- ✅ **Service DNS** — VM service is `victoriametrics` (not `…-server`); Alloy +
  Grafana corrected.
- ✅ **Alloy NodePort selector** — labels confirmed; OTLP reachable at
  `localhost:4317/4318`.
- ✅ **Metric naming** — confirmed `claude_code_*_<unit>_total` with `job="claude-code"`.
- ✅ **Dashboard bundle** — ColeMurray/claude-code-otel adopted and adapted
  (`job` label + datasource uids); see the ConfigMap header.
- ✅ **Delta vs cumulative** — Claude defaults to delta temporality, which the
  Prometheus/VM path silently drops. The env snippet above sets
  `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`.

Also resolved:

- ✅ **Chart versions** — pinned to the live-synced versions (no more `"*"`);
  Argo CD pinned to `v3.4.3`.
- ✅ **Client-agnostic metrics** — Alloy runs `otelcol.processor.deltatocumulative`,
  so metrics land even from clients that don't set the cumulative env var.
- ✅ **Reproducible dashboard** — `scripts/adapt-dashboard.rb` regenerates the
  ConfigMap from the vendored `dashboards/upstream/` JSON.

Still open:

- **Sparse panels** — commit/PR/lines-of-code panels stay empty until a session
  actually does that work.
