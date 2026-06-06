# 0004. Hosted deployment: authentication and per-developer isolation

Date: 2026-06-06

## Status

Accepted. Supersedes [ADR 0003](0003-two-parallel-stacks.md) **in the
[[Hosted deployment]] context only** — the local dual-stack remains for
[[Local deployment]].

## Context

ADRs 0001–0003 describe a single-machine, single-user [[Local deployment]]: one
[[Developer]]'s `claude` CLI exporting OTLP to a local kind cluster with no
authentication and Grafana `admin/admin`. Trust is "it's my laptop."

We now also want a [[Hosted deployment]] on Origoss' shared OKE cluster: a public
endpoint ingesting Claude Code telemetry from ~16 developers so the team can
understand its Claude Code usage. This inverts every trust assumption — public
internet, many named users, sensitive-by-default payload — and rides on existing
cluster infrastructure: Traefik as sole public ingress (foundation ADR 0017),
the agentgateway + Keycloak JWT gate (foundation ADR 0021), Grafana-style SSO
(foundation ADR 0023), and Argo CD GitOps.

Two facts constrained the design:

- **Claude Code's OTLP exporter does no OAuth/refresh by itself.** gRPC carries
  only a static `OTEL_EXPORTER_OTLP_HEADERS`; **http/protobuf** additionally
  supports an `otelHeadersHelper` script that Claude re-runs ~every 29 min, which
  can mint a fresh token. Org-level `.claude/settings.json` (MDM-distributed)
  sets these env vars at high precedence — users cannot override them.
- **The deployed agentgateway validates Keycloak JWTs only** (`jwtAuth.mode:
  strict` + CEL scope rules); there is no static-API-key path in the chart.

## Decision

**1. Network.** Ingest is public, behind Traefik at a host under
`oracle-apps.origoss.com`, TLS via the existing per-host HTTP-01 issuer.

**2. Ingest authentication (machine).** Each [[Developer]] is one Keycloak client
(`client_credentials`, scope `obs:write`). An `otelHeadersHelper` script on the
laptop fetches a short-lived JWT; the client exports over **http/protobuf** (port
4318). A new agentgateway route validates the JWT with the *same* `jwtAuth` + CEL
pattern already deployed for agentregistry, gating ingest on the `obs:write`
scope. Endpoint, auth, and telemetry env are pushed via MDM-locked managed
settings.

**3. UI authentication (human).** Grafana's native OIDC client points at the
Keycloak `agentregistry` realm (Google upstream), mirroring Argo CD SSO. Keycloak
group/email maps each login to a Grafana `Developer` or `Admin` role.

**4. Per-[[Tenant]] isolation (hard).** One Tenant per Developer.
- *Write*: agentgateway stamps `X-Scope-OrgID` from a developer-identity claim in
  the validated JWT; Alloy (`include_metadata` + `headers_setter`) forwards it to
  the stores.
- *Read*: Grafana forwards the logged-in user's OIDC identity to a read proxy
  that injects the matching `X-Scope-OrgID`; a separate `Admin` datasource reads
  cross-tenant for the aggregate view.
- **Tenant-key constraint (load-bearing):** the write-side JWT claim and the
  read-side OIDC identity MUST resolve to the *same* tenant string (a canonical
  developer identifier, e.g. email). The per-developer Keycloak client therefore
  emits that identifier as a claim. Mismatched keys silently break isolation —
  a developer sees nothing, or sees everyone.

**5. Store consolidation.** Hosted runs one multi-tenant store per [[Signal]] —
**VictoriaMetrics + VictoriaLogs + Tempo** — and drops Prometheus + Loki.
Prometheus OSS is single-tenant and cannot enforce (4); this is why ADR 0003's
dual-stack is superseded for hosted. The Prometheus-targeted community dashboards
(25255, ColeMurray) are re-pointed to VictoriaMetrics.

**6. Content & governance.** Prompt and tool-content bodies are **off**
(`OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_CONTENT` unset in managed settings). The
store holds productivity metadata only — sessions, token usage, cost, model mix,
tool-usage counts, lines-of-code, trace structure — never source, secrets, or
PII. Retention is **30 days** rolling, for data-minimization on named-employee
data.

### Decisions resolved (foundation issue #184)

- **FQDN:** ingest at `telemetry.oracle-apps.origoss.com`; Grafana at
  `grafana.ops.oracle-apps.origoss.com`.
- **gitops home:** the foundation cluster's Argo CD owns a multi-source Argo
  Application that syncs these manifests from *this* repo (foundation ADR 0019,
  multi-source workload delivery). The foundation declares only the platform glue
  — the agentgateway route, the per-developer Keycloak clients, and Traefik. The
  observability source of truth stays here, beside this ADR.
- **Keycloak realm:** reuse the existing `agentregistry` realm — add an
  `obs:write` client scope plus the per-developer clients; no new realm.
- **Tenant key:** the developer's **email**. Grafana receives it from the Google
  OIDC login; a Keycloak protocol-mapper stamps the same email into each
  developer's `client_credentials` ingest JWT, so the write-side and read-side
  tenants match — satisfying the load-bearing constraint in decision (4).

## Consequences

- Reuses the cluster's existing gate (agentgateway JWT + Keycloak + Traefik) with
  one new route and ~16 Keycloak clients — no new auth technology.
- Ingest moves off gRPC to http/protobuf — required for *both* the token-refresh
  helper and HTTP JWT validation at agentgateway.
- Hard isolation is the largest build: write-path tenant stamping + read-path
  identity proxy + cross-tenant admin view. Kept deliberately even after content
  was turned off, because per-developer cost/productivity figures are a
  performance-privacy concern, not a breach concern.
- The tenant-key alignment in (4) is the most failure-prone seam and must be
  tested end-to-end: a Developer sees only their own data; an Admin sees all.
- Local and Hosted now diverge: ADRs 0001/0002 hold for both; ADR 0003 holds for
  Local only.
- Content-off forgoes any future "review what was actually prompted" capability
  without a new decision (and the consent/retention/scrubbing wrapper it needs).
