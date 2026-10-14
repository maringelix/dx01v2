# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

### Added

- The app on the full local platform of tx01v2 (docs/LAB_LOCAL.md): overlay `local-platform`
  (Istio Gateway with HTTPS from cert-manager, HTTPRoutes, ExternalSecrets from `local-secrets`, HPA,
  `PeerAuthentication` STRICT, `AuthorizationPolicy` by identity, NetworkPolicies with HBONE,
  ServiceMonitor, five alert rules, a Grafana dashboard); `scripts/deploy-local.sh` (images to the lab
  registry, GitOps repository, Argo CD Application); `scripts/e2e-platform.sh` with probes (smoke over
  HTTPS through the emulated load balancer, mesh, observability, Trivy reports, HPA, database backup +
  restore drill, Argo CD self-heal, chaos experiment). Harness checks `promtool-rules` (tool promtool
  3.15.0) and `platform-e2e` (stage `platform`, `make e2e-platform`, CI job `e2e-platform`);
  `contract-app` asserts the new overlay.
- README status matrix: repository settings as code are applied (read back with `gh api`).

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

- The ruleset requires the CI job `e2e-platform` too (`.github/rulesets/main.json`, applied with
  `scripts/repo-guardrails.sh`): the local lab is a merge gate, not only maintainer discipline.
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
- The README family table and AGENTS.md link the Google Cloud pair (`tx03v2`, `dx03v2`), now public;
  `dx03v2` runs this same application (AGENTS.md rule 8 and the quarterly parity routine name it).
- One integration test case more, ported from `dx03v2` for parity: the
  `[<supplied>,]<client-ip>,<lb-ip>` `X-Forwarded-For` of the Google Cloud Application Load Balancer
  with `TRUST_PROXY_HOPS=2` (`api/test/integration/rate-limit.test.ts`).
- Dependabot ignores major bumps of the `node` build image (it follows `.nvmrc` and `engines.node`;
  a `node:26` bump fails `npm ci` with EBADENGINE).
- docs/SUSTENTACAO.md, "Estado atual": the stages say `verificado no CI` (the README already did).
