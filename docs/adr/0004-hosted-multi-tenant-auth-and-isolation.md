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
the agentgateway + Keycloak JWT gate (foundation ADR 0021), Argo CD-style native
OIDC SSO (foundation ADR 0023), and Argo CD GitOps.

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
scope (the observability analogue of agentregistry's `registry:write`). Endpoint,
auth, and telemetry env are pushed via MDM-locked managed settings.

**3. UI authentication (human).** Grafana's native OIDC client points at the
Keycloak `agentregistry` realm (Google upstream), mirroring Argo CD SSO. Roles
are mapped by **email allowlist** — Grafana `Developer` vs `Admin` — because the
Google-brokered token carries email but not Workspace groups (foundation ADR
0023 made the same choice for the same reason).

**4. Per-[[Tenant]] isolation (hard).** One Tenant per Developer.
- *Write*: agentgateway validates the JWT, then stamps `X-Scope-OrgID` from the
  developer's `tenant_id` claim; Alloy (`include_metadata` + batch `metadata_keys`
  + `otelcol.auth.headers`) forwards it to the stores — relabelled to `AccountID`
  for VictoriaMetrics/VictoriaLogs, whose tenants are numeric (see constraint below).
- *Read* (#187): Grafana OSS cannot inject a per-user tenant header (datasource
  headers are static), so all reads go through `agentgateway-obs-read` — a 2nd
  standalone agentgateway instance. Grafana forwards the user's Keycloak token
  (datasource `oauthPassThru`); the proxy validates it and `set`s the store tenant
  header from the token's `tenant_id` — Developer to their own tenant, Admin (email
  allowlist) to cross-tenant (VM `/select/multitenant`, Tempo pipe-list). The proxy is
  the SOLE enforcement point (one set of datasources, role-scoped per token, not Grafana
  datasource permissions which are Enterprise-only), and a `deny` rule blocks non-admins
  from any path-embedded tenant (VM ignores the AccountID header when the path carries a
  tenant). Logs admin cross-tenant is deferred — VictoriaLogs has no `/select/multitenant`.
- **Tenant-key constraint (load-bearing):** the write-side JWT and the read-side
  OIDC token MUST resolve to the *same* tenant. The wire tenant is a **numeric
  `tenant_id`** — VictoriaMetrics/VictoriaLogs tenants are 32-bit integers, so the
  email cannot be the wire value; the email is the human identity and the basis for
  assigning that number. Keycloak is the single source of truth: it stamps the same
  `tenant_id` onto both the per-developer `client_credentials` ingest JWT (write)
  and the Google-brokered Grafana login token (read). The gate also *requires* the
  claim (`has(jwt.tenant_id)`) — a token without it is rejected, never merged into
  another developer's tenant. Mismatched keys silently break isolation — a developer
  sees nothing, or sees everyone.

**5. Store consolidation.** Hosted runs one multi-tenant store per [[Signal]] —
**VictoriaMetrics + VictoriaLogs + Tempo** — and drops Prometheus + Loki.
Prometheus OSS is single-tenant and cannot enforce (4); this is why ADR 0003's
dual-stack is superseded for hosted. Hosted standardises on the VM-native **24640
VictoriaStack** dashboard (dotted OTLP names); the Prometheus-targeted community
dashboards (25255, ColeMurray) query normalised names (`claude_code_cost_usage_total`)
that do not exist in the dotted ingest, so they stay **local-only** rather than being
rewritten (#188 — one ingest = one naming; 24640 is the curated dashboard).

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
  `obs:write` client scope plus the per-developer clients; no new realm. This
  makes observability a third consumer of that shared realm (with Argo CD and
  agentregistry), enlarging the load-bearing blast radius foundation ADR 0023
  flagged: realm changes now affect all three.
- **Tenant key:** the developer's **email** is the human identity; the **wire
  tenant is a numeric `tenant_id`** mapped from it (VictoriaMetrics/VictoriaLogs
  tenants are 32-bit integers — see decision (4)). A Keycloak protocol-mapper stamps
  the same `tenant_id` into both the developer's `client_credentials` ingest JWT
  (write) and their Google-brokered Grafana login token (read), so write-side and
  read-side tenants match. *Refined during #186 implementation: the original "email
  is the wire key" did not hold — the Victoria stores require numeric tenants, so
  email maps to a numeric `tenant_id` that is the actual wire key.*

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
