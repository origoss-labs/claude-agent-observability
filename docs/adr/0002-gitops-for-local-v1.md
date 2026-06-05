# 2. GitOps with Argo CD for a single-machine local v1

Date: 2026-06-05

## Status

Accepted

## Context

v1 of the [[Platform]] runs on a local kind cluster on one developer's machine.
The in-cluster stack (Alloy, Tempo, Loki, VictoriaMetrics, Grafana) has to be
deployed reproducibly.

For an ephemeral single-machine cluster the lightest options are imperative:
plain Helm wrapped in a Makefile, or Helmfile (one declarative `helmfile sync`).
Neither needs a Git remote or a continuously-running controller.

GitOps (Argo CD) is the opposite trade: it adds a bootstrap step and a
controller, and — because Argo reconciles from a Git remote, not the working
copy — changes only land after a push. In return it gives declarative,
self-healing, drift-correcting deployment and a structure that extends cleanly to
multi-environment / shared-cluster v2.

## Decision

Deploy the stack with **Argo CD using the app-of-apps pattern**, syncing from the
GitHub remote `origoss-labs/claude-agent-observability`.

- Bootstrap: `kind create cluster` → install Argo CD (pinned upstream manifest)
  → `kubectl apply` the root Application.
- The root Application points at `apps/`, whose child Applications each pull an
  upstream Helm chart with inline values.
- Developer workflow is edit → push → Argo syncs.

We accepted the GitOps overhead on a local cluster to make v1 "platform-shaped"
rather than a one-off local script, and to avoid a rewrite when moving toward a
shared cluster later.

## Consequences

- A Git remote is required even for purely local work; uncommitted/unpushed
  changes are invisible to Argo. Internet access is needed to sync.
- One-time bootstrap (kind + Argo install + root app) before anything runs.
- The repo layout is GitOps-driven: `bootstrap/argocd/` for install + root app,
  `apps/<component>/` for child Applications.
- Drift correction and declarative redeploys come for free; tearing down is
  `kind delete cluster` (state lives on PVCs that die with the cluster).
- Path to multi-env v2 (ApplicationSets, multiple clusters) is incremental rather
  than a redesign.
