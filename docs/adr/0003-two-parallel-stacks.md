# 3. Two parallel stacks (Victoria + Prometheus), sharing only Grafana

Date: 2026-06-06

## Status

Accepted (supersedes part of [ADR 0001](0001-component-selection.md))

## Context

We want to run two community Claude Code dashboards from grafana.com as published,
with minimal per-panel adaptation:

- **24640 — "Claude Code (VictoriaStack)"** is built for the VictoriaMetrics
  datasource *plugin* (dotted OTLP metric names like `claude_code.token.usage`) and
  **VictoriaLogs** (LogsQL log panels).
- **25255 — "Claude Code Metrics (Prometheus)"** is built for a **Prometheus**
  datasource (normalised names: dots→`_`, `_total`/unit suffixes, e.g.
  `claude_code_token_usage_tokens_total`).

[ADR 0001](0001-component-selection.md) chose a single VictoriaMetrics store wired
as a *prometheus-type* datasource (no VM plugin) plus Loki for logs. That serves the
ColeMurray dashboard, but not 24640: 24640 needs the VM datasource plugin,
VictoriaLogs, and dotted names that the Prometheus-normalised `remote_write` path
does not produce.

A single store cannot carry both naming conventions cleanly. OTLP-native (dotted)
and Prometheus-normalised differ in both *metric* and *label* names, and classic
PromQL forbids dots in label names — so one datasource cannot serve both dashboards
without fragile, drift-prone query rewrites.

## Decision

Run **two parallel stacks**, each matching its dashboards' native backend, sharing
only the ingest gateway (forced: Claude exports to one OTLP endpoint) and Grafana:

- **Victoria stack** — VictoriaMetrics (OTLP-native, dotted names) + VictoriaLogs,
  surfaced through the `victoriametrics-metrics-datasource` and
  `victoriametrics-logs-datasource` plugins. Serves **24640**.
- **Prometheus stack** — Prometheus (native OTLP receiver, normalised names) + Loki,
  surfaced through `prometheus` + `loki` datasources. Serves **25255 + ColeMurray**.
- **Shared** — one Alloy fans the single Claude OTLP stream to both stacks
  (metrics→VM + Prometheus, logs→VictoriaLogs + Loki); one Tempo (neither dashboard
  uses traces — Tempo only powers trace→log correlation); one Grafana.
- All components stay in the `observability` namespace.

## Consequences

- Dashboards run essentially unmodified — adaptation is only datasource-uid
  resolution (`scripts/adapt-24640.rb`, `adapt-25255.rb`, `adapt-colemurray.rb`); no
  metric/label rewriting. Re-pulling newer revisions from grafana.com stays
  mechanical.
- Metrics are stored twice (dotted in VM, normalised in Prometheus) and logs twice
  (VictoriaLogs + Loki). For laptop-scale Claude telemetry this is negligible.
- ADR 0001's "VM as a prometheus-type datasource, no plugin" is superseded: we now
  run the VM datasource plugins **and** a real Prometheus. The best-tool-per-signal
  spirit holds, but we accept duplication to keep two communities' dashboards native.
- Alloy switched from `prometheus.remote_write` to OTLP-native exporters
  (`otelcol.exporter.otlphttp`) for metrics; `deltatocumulative` still feeds both
  (the Prometheus OTLP receiver and VM both want cumulative temporality).
- More components on the laptop (Prometheus + VictoriaLogs added), but still all
  filesystem/PVC — no object storage.
