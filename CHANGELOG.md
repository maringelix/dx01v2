# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

### Added

- Initial v2 of the AWS application lab, rebuilt from scratch with the lessons of v1
  (docs/ARQUITETURA.md, "v1 → v2"):
  - `api/`: Express 5 + TypeScript (strict, ESM) on Node.js 24 — message board with zod validation,
    JSON error model, per-client write rate limit keyed on `req.ip` with `trust proxy` as a hop
    count, constant-time admin token check, request IDs, pino logs with redaction, Prometheus
    metrics on a separate port, readiness that follows the database, graceful shutdown, migrations
    under an advisory lock.
  - `web/`: React 19 + Vite 8 page (accessible form and list, admin mode kept in memory), served by
    nginx-unprivileged with a strict CSP and security headers on every response.
  - Unit and integration tests (vitest + supertest against a real PostgreSQL 17) and web tests
    (Testing Library + jsdom) with coverage gates.
  - Images: distroless Node.js 24 runtime for the API (non-root, no shell, no npm) and
    nginx-unprivileged for the web, all bases pinned by digest; trivy HIGH/CRITICAL gate.
  - `compose.yaml` (project `dx01v2-dev`) with `scripts/dev-env.sh` and `scripts/compose-smoke.sh`.
  - Kubernetes manifests (kustomize): base, kind overlay with PostgreSQL, AWS overlays for the EKS
    cluster of tx01v2 (Ingress with WAF, ExternalSecrets, HPA, VPC-scoped NetworkPolicies, RDS TLS
    verify-full) validated with kubeconform and contract assertions.
  - kind end-to-end test (`scripts/e2e-kind.sh`): Pod Security `restricted`, smoke test, NetworkPolicy
    probes.
  - Harness (`scripts/harness.sh`, `make verify/build/e2e`) with pinned, SHA256-verified tools.
  - GitHub workflows `ci` (static, test, images, e2e) and `deploy-aws` (OIDC, environment `lab`),
    ruleset and repository settings as code, Dependabot, issue and PR templates, devcontainer.
  - Brazilian Portuguese docs: architecture, API, contract v1 (app side), runbook, guardrails,
    harness, sustainment, publication checklist.

### Changed

- The CI (`static`, `test`, `images`, `e2e`) ran green on GitHub: the README status matrix now says
  `verified in CI` for those rows (the compose row stays `verified locally`).
- Dependabot ignores minor and major updates of `typescript` (typescript-eslint 8.71 accepts
  `<6.1.0`; a TypeScript 7 PR failed `npm ci` with ERESOLVE) and minor updates of
  `nginxinc/nginx-unprivileged` (they would move the web image from the stable to the mainline nginx
  line). Both rules are reviewed in the quarterly routine (docs/SUSTENTACAO.md).
- The README family table links the Azure pair (`tx02v2`, `dx02v2`), now public; `dx02v2` runs this
  same application. AGENTS.md (rule 8) and docs/SUSTENTACAO.md (quarterly routine) add the parity
  rule between the app repositories.
- One integration test case more, ported from `dx02v2` for parity: the comma-only
  `X-Forwarded-For` format of Application Gateway for Containers (`api/test/integration/rate-limit.test.ts`).
