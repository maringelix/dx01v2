# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

- Standardize documentation, historical evidence, templates and instructions in English; rename
  document paths and use one README linked to the central onboarding guide. Refresh AWS
  publication/promotion prerequisites. Translate public UI copy and locale to English without
  changing application behavior or payload contracts; retain Unicode test data.

- R9: consume contract v7 in either region, preserve current replicated credentials while selecting
  the regional database endpoint, isolate GitOps branches and verify recovery before DNS cutover.

### Added

- R9 independent Docker A/B recovery gate: verified backup/configuration, PostgreSQL TLS,
  reconnect without API restart, live-writer promotion refusal, corruption rejection, primary
  disk loss, measured RPO/RTO and fenced failback preserving writes made in the secondary.
  The job and release gates require the exact tested/scanned images; cloud recovery is unrun.
### Fixed

- Keep pod-IP metrics scraping reachable only to the authenticated Prometheus identity on port
  9464, while API traffic still requires the waypoint. The Collector's synthetic web probe is
  limited to GET /healthz. Manifest checks enforce both narrow exceptions.

- Permit HBONE on the generated Istio waypoint under namespace default-deny, with egress limited
  to the app, mesh demo, control plane and telemetry. AuthorizationPolicy still enforces client
  identity and HTTP rules; the waypoint Service remains ClusterIP.

- The platform rollback exercise pins its mesh demo to the tested R8 API image while it deploys the
  older application image. This keeps the mesh pods healthy when the earlier release predates the
  mesh demo, and still exercises an actual previous app artifact. The workflow source check also
  matches its main-branch expression literally without a ShellCheck false positive.

### Added

- Complete the dx side of R8.1–R8.4 with the version 6 AWS contract, separate `core|full` deploy
  overlays, and an isolated mesh canary exercise. The workflow attests promoted ECR digests with its
  keyless GitHub identity; tx01v2's Kyverno policy checks that exact signer before admitting app
  Pods. The application, mesh probes, and contract render are covered by CI; AWS runtime remains
  `not run in the cloud (v2)`.

- R8.1 AWS DNS/TLS integration: the deployment consumes the v5 tx01v2 SSM contract, selects HTTPS
  only when Route53 and ACM are enabled, routes the configured hostname, and derives its smoke URL
  from that contract. No manually supplied certificate ARN or DNS URL is needed.

- R7 DevSecOps gates: CodeQL `security-extended` with a fail-closed SARIF severity threshold, a real
  SonarQube Community Build Quality Gate with LCOV and a negative coverage fixture, Trivy dependency
  scanning, OWASP ZAP Baseline against a disposable local Compose deployment, and a Gitleaks check
  that fails closed when history is not scanned and proves secret detection with a redacted random
  fixture. A manual, no-rebuild publication workflow verifies the exact successful CI run, creates
  SPDX SBOM and SLSA provenance attestations for GHCR image digests with keyless Sigstore signing,
  and tests rejection of an unsigned image and incorrect signer/issuer. See
  [docs/CI_SECURITY.md](docs/CI_SECURITY.md); CI evidence is required before this capability is
  marked verified.

- The application DAST policy now fails on selected missing security headers, while retaining all
  other ZAP warnings in its reports. The web entry point sends COEP and CORP headers and the smoke
  test asserts their values.

- Cloud deploy now publishes the app source revision to `gitops/aws` with example parameters, then
  waits for Argo CD to report that exact revision `Synced` and `Healthy`. Direct push remains
  available through the script when Argo CD is not managing the app; the Actions workflow always
  uses GitOps.
- Contract version 4 with tx01v2 records the R4 Argo CD Application and refresh permission; cloud
  values are configured on the live Application while the public branch contains only example parameters.


### Security

- `deploy/local/tx01v2.ref` pins the local platform to the merged tx01v2 R4 commit, so
  `e2e-platform` and `family-ref` check the integrated infrastructure.

- Contract version 3 with tx01v2, coordinated with [tx01v2#14](https://github.com/maringelix/tx01v2/pull/14):
  the deploy identity now documents the immutable GitHub owner and repository IDs; its workflow uses
  the protected `lab` environment (roadmap R3.15). The version 2 application parameters and tracing
  requirements remain in place.
- The smoke test never sends the admin token over plain HTTP to another machine (roadmap R3.17): it
  is sent over HTTPS or to `127.0.0.1`; on any other plain HTTP entry point, such as the AWS lab
  without a certificate, the one call that needs it is skipped (`SKIP` in the output) and
  `scripts/deploy-aws.sh` does not even read the token.
- `scripts/repo-guardrails.sh` (same file in the six lab repositories, roadmap R3.15 and R3.18) fails
  instead of skipping when it cannot protect the environment `lab`, leaves only `main` in it, reads it
  back, fails when the OIDC subject of the repository is name-based (the cloud trust expects the
  immutable one with the owner and repository IDs) and refuses an argument that is not the
  repository of the clone.
- `scripts/e2e-platform.sh` keeps the state of its lab in a directory of its own, so a lab you keep
  with `make local-up` in tx01v2 is never adopted and destroyed by it, and reads diagnostics only
  through the kubeconfig of the lab: until the lab exists, `kubectl` has no cluster to reach.
- `make clean` removes things only under the directory of the Makefile, wherever make was started
  from (roadmap R3.18).
- The integration tests drop and recreate tables (`messages`, `schema_migrations`), and with
  `DB_HOST` set the harness ran them against whatever database `DB_*` pointed at, such as the
  development database of `docs/RUNBOOK.md`. They now refuse a `DB_NAME` that does not end in `_test`,
  both in `api/test/integration/helpers.ts` (`requireTestDatabase`, new unit test `test-database`) and
  in `scripts/harness.sh`; `docs/RUNBOOK.md` shows a separate `dx01v2_test` database.
- `scripts/deploy-local.sh` refuses any kube context but `kind-tx01v2-local`: a cluster of whoever runs
  it, left in the current context, never receives the deploy.
- `docs/RUNBOOK.md` writes the kubeconfig of the cloud lab to its own file
  (`~/.kube/tx01v2-lab.kubeconfig`): `~/.kube/config` and its current context stay as they were.
- `deploy/local/tx01v2.ref` follows tx01v2 to the commit where its scripts act only on the lab.

### Fixed

- `scripts/e2e-platform.sh` runs the branch-image smoke assertions after the zero-downtime rollout
  promotes that image; the initial platform state intentionally uses the previous `main` image for
  rollback coverage.
- `scripts/deploy-local.sh` waits until each Deployment has the expected image tag before checking its
  rollout, so Argo CD sync status cannot make the previous image look like the new release.

- `scripts/deploy-local.sh` waits for the Argo CD sync of the commit it pushed: on a redeploy the
  Application was still Synced and Healthy on the previous commit, and the script went on too early.

### Added

- `LOCAL_SIZE=small` for the platform e2e (roadmap R1.8): `scripts/e2e-platform.sh` passes it to the
  tx01v2 platform, which installs the same components with smaller memory limits, short retention and
  fewer series and workers. `make e2e-platform-small` (CI job `e2e-platform-small`, not a required
  check) runs the 18 probes inside a Docker-in-Docker limited to 7 GB without swap and reports the peak
  memory, the largest containers and any OOM kill. Measured on 2026-10-15: the 18 probes pass at 7 GB in about 14 minutes (4.4 GiB of anonymous
  memory; in one of four runs across the three pairs the kernel killed the plugin copy of Velero, an
  init container the kubelet runs again); at 6 GB, the goal of the roadmap, the rollout probe loses requests, so the size
  stays at 7 GB (decision of Bruno). `deploy/local/tx01v2.ref` follows tx01v2 to the commit with the
  sizes.
- Traces with OpenTelemetry ("Observability 2.0", the last step of the v1 roadmap, never started
  there): the API creates a SERVER span per request (named after the route) and a CLIENT span per
  PostgreSQL query inside it (parameterized SQL only), continues the W3C `traceparent` of the Gateway
  and exports OTLP/HTTP to `OTEL_EXPORTER_OTLP_ENDPOINT` (off without it: compose, kind, tests). Manual
  spans with `@opentelemetry/api` 1.9.1, `sdk-trace-node` 2.12.0, `exporter-trace-otlp-http` 0.223.0,
  `resources` 2.12.0 and `semantic-conventions` 1.43.0, no ESM loader hook; `/healthz` and `/readyz`
  are not traced; shutdown flushes the spans for at most 5 s and never fails because of the Collector.
  Log lines carry `trace_id`/`span_id`, and `/metrics` speaks OpenMetrics with the trace id as an
  exemplar of the latency histogram. New unit and integration tests (`telemetry`, `tracing`).
- Contract version 2 with tx01v2: the overlay `local-platform` sends the traces to the Collector of the
  local contract (`tracing.otlp-endpoint`, required by `scripts/deploy-local.sh`), the component `aws`
  to `opentelemetry-collector.observability.svc:4318` (`not run in the cloud (v2)`). NetworkPolicies
  widened only for that: API → Collector (4318) and Gateway → Collector (4317, its spans), both over
  HBONE (15008) in the mesh; `contract-app` asserts both.
- `make e2e-platform` has 18 probes (was 13): one trace in Tempo from the Gateway to the query, the
  `trace_id` in the log lines in Loki and in an exemplar in Prometheus; a zero-downtime rollout (a new
  version through GitOps, no failed request of a reader); 200 ms of latency between the API and
  PostgreSQL (NetworkChaos), every read passes and the trace shows the delay in the query span.
- `FORK.md`: forking the app step by step (the steps shared with tx01v2, the local runs, testing against
  your own tx01v2, deploying to your own cloud account, troubleshooting), linked from both READMEs and
  CONTRIBUTING.md; the harness requires it.
- `scripts/e2e-platform.sh` takes `TX01V2_REPO` (an https URL; the CI job `e2e-platform` passes the
  repository variable of the same name): a fork can test against its own tx01v2. A pinned commit that is
  not in that repository fails with a clear message.
- The devcontainer declares 4 CPUs and 8 GB (the platform e2e runs the whole local lab).
- The app on the full local platform of tx01v2 (docs/LOCAL_LAB.md): overlay `local-platform`
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
  (docs/ARCHITECTURE.md, "v1 → v2"):
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

- `deploy/local/tx01v2.ref` follows tx01v2 to `3895fc2` (tx01v2#12, the debts round of the roadmap).
- Comments, script messages and docs say "the contract" or point to `docs/CONTRACT.md` instead of
  "contract v1": the contract has been at version 2 since round 1 (roadmap S.8).
- The family table of both READMEs links the family hub `tx00v2` (roadmap, family guardrails,
  cross-repo checks).
- `scripts/repo-guardrails.sh` also turns issues on (the issue forms) and requires approval for
  workflow runs from forks of external contributors; the reviewer of the `lab` environment is the gh
  user that runs it. It fails while the workflows of a fork are still disabled and notes a renamed
  repository or a CODEOWNERS that names someone else (tested against a stub gh, then applied to the
  original repository and read back with `gh api` on 2026-10-14).
- The ruleset requires the CI job `e2e-platform` too (`.github/rulesets/main.json`, applied with
  `scripts/repo-guardrails.sh`): the local lab is a merge gate, not only maintainer discipline.
- The CI (`static`, `test`, `images`, `e2e`) ran green on GitHub: the README status matrix now says
  `verified in CI` for those rows (the compose row stays `verified locally`).
- Dependabot ignores minor and major updates of `typescript` (typescript-eslint 8.71 accepts
  `<6.1.0`; a TypeScript 7 PR failed `npm ci` with ERESOLVE) and minor updates of
  `nginxinc/nginx-unprivileged` (they would move the web image from the stable to the mainline nginx
  line). Both rules are reviewed in the quarterly routine (docs/MAINTENANCE.md).
- The README family table links the Azure pair (`tx02v2`, `dx02v2`), now public; `dx02v2` runs this
  same application. AGENTS.md (rule 8) and docs/MAINTENANCE.md (quarterly routine) add the parity
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
- docs/MAINTENANCE.md, "Current state": the stages say `verified in CI` (the README already did).

## R10: capacity and FinOps

See [Capacity and SLO](docs/FINOPS.md) for bounded load, HPA scale-up/down, PDB/drain,
rightsizing, PostgreSQL pooling and showback. Docker proof runs in Actions; nothing has run in AWS v2.
