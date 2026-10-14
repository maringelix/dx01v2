# AGENTS.md

Instructions for AI coding agents and humans working in `dx01v2`. `CLAUDE.md` points here; this file
is the source of truth. The full rule list (pt-BR) is [docs/GUARDRAILS.md](docs/GUARDRAILS.md).

## 1. Mission and context

- `dx01v2` is the application half of a public, educational DevOps lab (v2 family: `tx01v2` +
  `dx01v2` on AWS, `tx02v2` + `dx02v2` on Azure, `tx03v2` + `dx03v2` on Google Cloud). Every app
  repository of the family runs this same application; only the deploy target changes.
- The app is a small message board: Express 5 + TypeScript API, React 19 page served by
  nginx-unprivileged, PostgreSQL 17; Kubernetes manifests (kustomize) for kind and for the EKS
  cluster of `tx01v2`.
- It must stay healthy without any cloud account: every claim is backed by the harness or carries a
  status label (`verified in CI`, `verified locally`, `not run in the cloud (v2)`, `planned`).
- Current status: static, test, build and the kind e2e pass locally in Linux containers and in CI
  (jobs `static`, `test`, `images`, `e2e`). **Nothing of v2 has run in AWS** (`deploy-aws` is
  `not run in the cloud (v2)`).
- The app also runs on the full local platform of tx01v2 (kind, Istio ambient, Argo CD, Prometheus,
  Loki, Tempo and the OpenTelemetry Collector, Gatekeeper, Trivy Operator, chaos): overlay `local-platform`, `scripts/deploy-local.sh` (GitOps)
  and `make e2e-platform` (CI job `e2e-platform`, [docs/LAB_LOCAL.md](docs/LAB_LOCAL.md)). It is not
  cloud-mutating: agents may run it, one heavy run at a time (Docker with 8 GB).
- The interface with `tx01v2` is [docs/CONTRATO.md](docs/CONTRATO.md) (contract v2, owned by tx01v2; the
  local lab has its own local contract, `lab-system/lab-contract`).

## 2. Non-negotiable rules

1. Never commit secrets or real identifiers (AWS account IDs, hostnames, public IPs, e-mails). Use
   `123456789012`/`<ACCOUNT_ID>`, `203.0.113.10/32`/`<YOUR_IP>/32`, `you@example.com`. Local
   credentials are generated at runtime (`scripts/dev-env.sh`, `scripts/e2e-kind.sh`).
2. Never run cloud-mutating actions — `scripts/deploy-aws.sh`, `kubectl`/`helm` against a cloud
   cluster, AWS write API calls, dispatching `deploy-aws` — unless a human explicitly asks for that
   action in the current task. Read-only `gh api` lookups are fine.
3. Never weaken a gate: no `continue-on-error`, no `|| true` on checks, no `--no-verify`, no lowered
   coverage thresholds, no disabled or skipped checks, no new scanner ignores without `statement` +
   `expired_at`.
4. Never widen IAM, network (NetworkPolicy, Ingress), RBAC or CORS without stating why in the PR.
   The API has no CORS middleware on purpose (same origin).
5. Keep the contract: changes need coordinated PRs in `tx01v2` and `dx01v2` and a version bump.
6. Pin every new dependency, action and image (exact npm version + lockfile, 40-char SHA +
   `# vX.Y.Z`, image digest, tool version + SHA256) and update the docs in the same change.
7. Once the ruleset is on, never push to `main`: pull requests only.
8. Keep parity with the other app repositories (`dx02v2` and `dx03v2`): a change to `api/` or
   `web/` is ported to all of them, or the PR says why it is AWS-only; `e2e/` differs only where the
   edge differs (ALB + WAF here, Application Gateway for Containers in dx02v2, the GKE Gateway with
   Cloud Armor in dx03v2).

## 3. Repo map

```text
api/                    Express 5 API (src/, migrations/*.sql, test/unit, test/integration, Dockerfile)
web/                    React 19 page (src/, nginx/default.conf + security-headers.conf, Dockerfile)
e2e/                    smoke.mjs + lib.mjs: the smoke test for compose, kind and the ALB (no dependencies)
deploy/k8s/base/        Deployments, Services, ConfigMap, PDBs, NetworkPolicies, ServiceAccounts
deploy/k8s/overlays/    local (kind: namespace, PostgreSQL), aws, aws-https (EKS of tx01v2), local-platform
deploy/k8s/components/  aws (Ingress, ExternalSecrets, HPA, VPC policies, params), aws-https, local-platform
kind/                   kind-config.yaml (node image pinned by digest)
compose.yaml            local stack dx01v2-dev; .env from scripts/dev-env.sh (.env.example has placeholders)
scripts/harness.sh      every check of the harness (stages static, test, build, e2e, all, list)
scripts/install-tools.sh            pinned tools into .tools/ (SHA256-verified)
scripts/update-tool-checksums.sh    bump a tool: versions.env + checksums.txt from upstream checksums
scripts/e2e-kind.sh     kind e2e (cluster dx01v2-e2e); scripts/compose-smoke.sh, scripts/dev-env.sh
scripts/deploy-aws.sh   AWS deploy (cloud-mutating; used by .github/workflows/deploy-aws.yml)
scripts/deploy-local.sh GitOps deploy to the tx01v2 local lab (registry, GitOps repository, Argo CD)
scripts/e2e-platform.sh the app on the full local platform + probes (stage platform)
deploy/local/           tx01v2.ref: the tx01v2 commit the platform e2e uses
scripts/render-k8s.sh   render an overlay without touching the repo; check-manifests.mjs asserts the contract
scripts/repo-guardrails.sh          repository settings via gh api (run by the maintainer, and once by every fork owner)
scripts/lib/            shared bash helpers (common, tools, k8s)
tools/                  versions.env and checksums.txt of the harness tools
.github/                ci.yml (static, test, images, e2e), deploy-aws.yml, ruleset, templates, Dependabot
.devcontainer/          Node.js 24 + Docker-in-Docker, pinned by digest (runs make tools)
docs/                   pt-BR docs: architecture, API, contract, runbook, guardrails, harness, sustainment
FORK.md                 how to fork the lab: what GitHub does not copy, the local lab, your own cloud account
```

## 4. Setup

- Linux or WSL 2 (Ubuntu) with Docker, bash >= 4.4, Node.js 24 (`.nvmrc`), curl, unzip, xz, git,
  make: `make tools`. `make verify` runs `npm ci` itself.
- Windows/macOS: open the repo in the devcontainer (Node.js 24 + Docker-in-Docker; it runs
  `make tools`). macOS without the devcontainer: `brew install bash`.
- The integration tests need PostgreSQL: set `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
  `DB_PASSWORD`, or let the harness start a throwaway `postgres:17-alpine` container.
- No cloud credentials are needed for anything except `deploy-aws`.

## 5. Harness commands

| Command | Runs | When |
|---|---|---|
| `make tools` | `scripts/install-tools.sh` (all pinned tools) | first time, after a tool bump |
| `make static` | `scripts/harness.sh static`: policies, npm ci, eslint, prettier, tsc, hadolint, actionlint, shellcheck, kubeconform, contract, trivy config, gitleaks | every change |
| `make test` | `scripts/harness.sh test`: API unit + integration (real PostgreSQL), web tests, coverage gates | every code change |
| `HARNESS_STRICT=1 make verify` | static + test with SKIP = FAIL (CI jobs `static` and `test`) | before every PR |
| `make build` | npm build, both images, image policy, trivy image gate (CI job `images`) | code, Dockerfile or dependency changes |
| `make e2e` | kind cluster, smoke test, Pod Security and NetworkPolicy probes (CI job `e2e`) | manifest, image or app changes |
| `make e2e-platform` | the app on the full tx01v2 local platform through GitOps + probes (CI job `e2e-platform`) | manifest, image or app changes |
| `scripts/harness.sh list` | lists all checks | any time |

## 6. Definition of Done

- [ ] `HARNESS_STRICT=1 make verify` green locally (plus `make build` and `make e2e` when images,
      manifests or the app changed); CI green (`static`, `test`, `images`, `e2e`, `e2e-platform`).
- [ ] Docs, README status matrix and `CHANGELOG.md` (`[Unreleased]`) updated in the same PR.
- [ ] No new unexplained scanner ignores; no weakened checks or coverage thresholds.
- [ ] Contract respected (or bumped with a linked `tx01v2` PR).
- [ ] New dependencies pinned; `package-lock.json` in sync; no secrets or real identifiers.

## 7. Playbooks

**Maintainer / sustentação.** Follow [docs/SUSTENTACAO.md](docs/SUSTENTACAO.md): react to a red
scheduled CI (often a new CVE in a base image), merge monthly Dependabot PRs, run the quarterly
review (harness tools, image digests, Node.js/PostgreSQL/Kubernetes calendar, kubeconform schema
commits, ignores close to `expired_at`).

**Reviewer.** Check the PR template boxes; confirm the harness is green; look for widened
NetworkPolicies/RBAC/Ingress, CORS or `trust proxy` changes, inline styles or raw HTML in the UI,
unpinned references, ignores without justification, lowered coverage, docs claiming more than the
harness proves, and contract changes without a version bump.

**Dependency updater.** One Dependabot group per PR. Read the release notes (majors: migration
guide). npm: the lockfile must stay in sync (`npm ci` in the harness proves it) and versions stay
exact; `typescript` must stay inside the range supported by `typescript-eslint`. Docker digests:
`api/Dockerfile` and `web/Dockerfile` share the same `node` build image. Actions: confirm the new SHA
matches the tag comment. Harness tools are bumped only with `scripts/update-tool-checksums.sh`.

**Cloud operator** (only with explicit human approval for that action): follow
[docs/RUNBOOK.md](docs/RUNBOOK.md) and the tx01v2 runbook, always finish with the tx01v2 destroy +
leftover check, and file a `cloud_run_report` issue. Never leave a lab running unattended.

## 8. Common tasks

- Add an API endpoint: route in `api/src/routes/`, input schema in `api/src/validation.ts`, errors
  through `HttpError`; `trackRoute` as the first handler (metrics label); unit + integration tests;
  document it in `docs/API.md`.
- Add a migration: a new `api/migrations/NNNN_name.sql` (never edit an applied file: the checksum
  check refuses it); the integration tests run every migration.
- Add an environment variable: `api/src/config.ts` (zod schema, readable error), test in
  `api/test/unit/config.test.ts`, then `compose.yaml`, `deploy/k8s/base/configmap.yaml` (or a
  Secret), `docs/API.md`.
- Trace something new: spans are created by hand in `api/src/telemetry.ts` (no auto-instrumentation
  loader); never put request bodies, query values or tokens in span attributes; test it with the
  in-memory processor (`api/test/unit/telemetry.test.ts`, `api/test/integration/tracing.test.ts`).
- Change a security header: `web/nginx/security-headers.conf` (included in every location) and the
  expectations in `e2e/smoke.mjs`.
- Change a NetworkPolicy: update `scripts/check-manifests.mjs` and the probes in `scripts/e2e-kind.sh`.
- Bump a harness tool: `scripts/update-tool-checksums.sh <tool> <version>`, then `make tools verify`.
- Add a check: docs/HARNESS.md ("Como adicionar um check").

## 9. When to stop and ask a human

- Any action that changes or costs money in a cloud account, or needs credentials.
- A check fails for a reason outside the repository (upstream outage, a base image CVE without a
  fix, a broken schema catalog) — report it; do not weaken or skip the check.
- A contract change, an IAM/RBAC/network/CORS widening, or a new scanner ignore.
- Rewriting git history, force-pushing, changing repository settings or rulesets.
- Anything that would make a README/doc claim stronger than the evidence.
