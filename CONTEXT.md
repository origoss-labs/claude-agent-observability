# Context: Claude Agent Observability

Ubiquitous language for this project. Glossary only — no implementation details.

## Glossary

### Claude Agent
The telemetry **source**. In v1, a Claude Code CLI session running on a
developer's laptop with OpenTelemetry enabled, exporting OTLP to the platform.
Not (yet) an in-cluster Agent SDK workload — that is a possible future source,
deliberately not precluded by the design.

### Platform
The system being built: it ingests, stores, and visualises telemetry emitted by
[[Claude Agent]]s. Runs on Kubernetes; v1 targets a local kind cluster.
Components are chosen on merit per [[Signal]], not constrained to a single
vendor — Grafana for visualisation, plus whichever store fits each signal best.

### Signal
A category of telemetry. Three kinds, all emitted by a [[Claude Agent]] over OTLP:
- **Trace** — distributed spans of one agent interaction (`claude_code.interaction`
  root with `llm_request` / `tool` / `hook` children). Beta feature of the source.
- **Metric** — time series: sessions, token usage, cost, lines of code.
- **Event/Log** — discrete records: user prompts, tool decisions, API requests.
