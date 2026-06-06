# 1. Component selection: best-tool-per-signal, not single-vendor

Date: 2026-06-05

## Status

Accepted — superseded in part by [ADR 0003](0003-two-parallel-stacks.md), which adds
a parallel Prometheus + VictoriaLogs stack (and the VM datasource plugins) so two
community dashboards run on their native backends.

## Context

The platform ingests three signals from [[Claude Agent]]s — traces, metrics, and
logs — and visualises them. The initial brief said "built on Grafana products,"
which would point at the full LGTM stack: Loki, Grafana, Tempo, Mimir.

Mimir is the Grafana metrics store. On a single-machine local kind cluster it is
the heaviest option: it expects object storage and runs multiple components even
in monolithic mode. VictoriaMetrics single-node, by contrast, is one small Go
binary, needs no object storage (plain local disk), ingests OTLP natively, and is
PromQL-compatible — but it is not a Grafana product.

The "Grafana products" framing was therefore in tension with footprint on a
laptop-scale cluster. We chose to relax it.

## Decision

Choose each component on merit for the signal it serves, not by vendor:

- **Metrics** — VictoriaMetrics (single-node). Lightest, no object storage,
  OTLP-native, PromQL via a Prometheus-type Grafana datasource.
- **Traces** — Grafana Tempo. Mature, standard OTLP trace store; VictoriaTraces
  was too new to bet v1 on.
- **Logs** — Grafana Loki. Chosen specifically for turnkey trace↔log correlation
  with Tempo, over the lighter VictoriaLogs.
- **Visualisation** — Grafana.
- **Ingest** — Grafana Alloy (single OTLP gateway, fans out to the three stores).

So the stack is Grafana for ingest/traces/logs/viz, VictoriaMetrics for metrics.

## Consequences

- Two ecosystems coexist. Metrics queries are PromQL against VM (MetricsQL
  superset available); logs are LogQL; traces are TraceQL.
- VM is wired as a **Prometheus-type** datasource — no VM plugin needed, but VM
  features beyond the Prometheus API aren't exposed.
- Footprint stays laptop-friendly: VM needs no object storage; only Tempo and
  Loki use the filesystem backend on PVCs.
- A future reader sees a non-Grafana metrics store in an otherwise-Grafana repo;
  this ADR is why. Reverting to Mimir is possible but means re-pointing the
  metrics datasource and re-checking dashboard queries.
- The community dashboard bundle (ColeMurray/claude-code-otel) assumes
  Prometheus; it works against VM via the Prometheus datasource, after adapting
  metric names to the normalised OTel→Prometheus form.
