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
[[Claude Agent]]s. Runs on Kubernetes in one of two deployment modes
([[Local deployment]] / [[Hosted deployment]]). Components are chosen on merit
per [[Signal]], not constrained to a single vendor — Grafana for visualisation,
plus whichever store fits each signal best.

### Local deployment
The single-machine, single-user mode: a local kind cluster, one [[Developer]],
no auth, no isolation. The v1 target.
_Avoid_: dev mode, kind mode

### Hosted deployment
The shared mode: the Platform running on the team's OKE cluster, ingesting from
many [[Developer]]s over a public endpoint, with per-developer authentication
and per-[[Tenant]] view isolation.
_Avoid_: prod mode, cloud mode, production

### Developer
The identified human who owns a [[Claude Agent]]. First-class in
[[Hosted deployment]]: telemetry is authenticated and attributed per Developer,
and each Developer maps to exactly one [[Tenant]].
_Avoid_: user, engineer, employee

### Tenant
The per-[[Developer]] isolation boundary inside the multi-tenant stores. One
Tenant per Developer; a Developer sees only their own Tenant, an [[Admin]] sees
all Tenants in aggregate.
_Avoid_: org, account, namespace

### Admin
A Developer additionally allowed to see every [[Tenant]] in aggregate (team
totals, per-person drill-down). The only role exempt from per-Tenant isolation.
_Avoid_: lead, manager, superuser

### Signal
A category of telemetry. Three kinds, all emitted by a [[Claude Agent]] over OTLP:
- **Trace** — distributed spans of one agent interaction (`claude_code.interaction`
  root with `llm_request` / `tool` / `hook` children). Beta feature of the source.
- **Metric** — time series: sessions, token usage, cost, lines of code.
- **Event/Log** — discrete records: user prompts, tool decisions, API requests.
