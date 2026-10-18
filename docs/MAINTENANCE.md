# Maintaining dx01v2

Keep the repository healthy without a cloud account: routines, support calendar and procedures.
Dates/versions below preserve the snapshot checked on 2026-10-10; this language migration does
not claim a new lifecycle review. Consult current upstream sources before upgrades.

## 1. Goal and scope

Covers app source (API, page, migrations), npm dependencies, base images, manifests, generated
CRD schemas, scripts/workflows, harness tools, parity with dx02v2/dx03v2 and optional cloud runs.
Infrastructure (EKS, ALB, WAF, RDS, Secrets Manager, platform) belongs to tx01v2
and its maintenance guide.

## 2. Current status

- Static/test/build/e2e: verified in CI (static/test/images/e2e) and local Linux containers.
- AWS deployment: not run in the cloud (v2).
- Current contract is version 7/R9 (2026-10-17), with regional runtime and db/endpoint; v3 pinned immutable OIDC and v2 added Collector OTLP.

- Scanner exceptions: none in the recorded baseline (.trivyignore.yaml empty).

## 3. Routines

| When | What | How |
|---|---|---|
| Weekly, automatic | scheduled Monday 06:00 UTC CI runs every job, including image trivy | failures: section 6; typical causes are new base/dependency CVEs, changed URLs or network |
| Monthly | Dependabot PRs for npm, Docker, actions, pre-commit | AGENTS dependency-updater playbook; one PR/group, green CI before merge; port same bumps to other apps |
| Quarterly | harness tools; PostgreSQL/kind/devcontainer digests; Node.js/nginx/Kubernetes/EKS; platform matching tx01v2; kubeconform catalogs; near-expiry ignores; app parity | sections 4–5; record CHANGELOG |
| Before cloud run | read README/tx01v2 COSTS, green commit CI, applied TX/platform, GitHub variables | RUNBOOK.md |
| During cloud run | timestamps, smoke output, issues; never leave overnight | RUNBOOK.md |
| After cloud run | tx01v2 destroy, clean leftovers, cloud_run_report; change status only with evidence | RUNBOOK.md |

## 4. Support calendar

Historical snapshot, checked 2026-10-10; preserve dates while verifying live sources at each review.

| Component | Version | Support end | Source | Action |
|---|---|---|---|---|
| Node.js | 24 (.nvmrc; images 24.21.0) | 2028-04-30 | [Node schedule](https://github.com/nodejs/Release#release-schedule) | move to 26 after LTS with time to spare, coordinated across apps; section 5.3 |
| Node.js | 26 | LTS 2026-10-28; end 2029-04-30 | same | candidate for first quarterly review after 2026-10-28 |
| TypeScript | 6.0.3 | no published date | [typescript-eslint support](https://typescript-eslint.io/users/dependency-versions) | retain >=4.8.4 <6.1.0 for typescript-eslint 8.71; Dependabot ignores TS minor/major |
| React/Vite/Vitest | 19.3/8.3/5.0 | no published calendar | react.dev, vite.dev, vitest.dev | separate major PRs; read migration guides |
| Express | 5.3 | active 5.x | [support policy](https://expressjs.com/en/support/) | Dependabot |
| OpenTelemetry JS | @opentelemetry/api 1.9.1; sdk-trace-node/resources 2.12.0; exporter-trace-otlp-http 0.223.0; semantic-conventions 1.43.0 | stable API 1.x/SDK 2.x; experimental exporter 0.x; fixes only current line, no calendar | [OTel JS releases](https://github.com/open-telemetry/opentelemetry-js/releases) | bump together across all three apps; SDK 2.x and exporter 0.2xx share releases; exporter minor may break; run telemetry/tracing/platform tests |
| PostgreSQL | 17, postgres:17-alpine, image 17.11 | community 2029-11-08 | [version policy](https://www.postgresql.org/support/versioning/) | major follows tx01v2 Flexible Server contract; update Compose/CI/kind/harness together |
| nginx web | stable 1.30, nginxinc/nginx-unprivileged:1.30.5-alpine3.24-slim | next stable 1.32, expected around April 2027 | [nginx](https://nginx.org/en/download.html) | next quarterly review after release |
| Alpine build/web runtime | 3.24 | approximately 2028-05 | [releases](https://alpinelinux.org/releases/) | follow node/nginx-unprivileged digests |
| Distroless API | nodejs24-debian13:nonroot | Debian 13 security approximately 2028-08 and Node.js 24 | [distroless](https://github.com/GoogleContainerTools/distroless) | do not revert to debian12, which stopped at Node 24.14.0 |
| Kubernetes (kind/kubectl/schemas) and EKS | 1.36; node v1.36.4, kubectl 1.36.5 | upstream ~2027-06; EKS standard support 2027-08-02 | [Kubernetes](https://kubernetes.io/releases/), [EKS calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) | coordinate tx01v2 minor changes as contract changes; section 5.5 |
| kind | v0.33.0; its default Kubernetes 1.37.0 | no EOL policy | [releases](https://github.com/kubernetes-sigs/kind/releases) | quarterly; node image from release notes, digest-pinned |
| Runners/devcontainer | Ubuntu 24.04 LTS; Debian 13 javascript-node:24-trixie | Ubuntu 2029-04 | ubuntu.com, debian.org | replace before EOL |
| Trivy exceptions | none | — | .trivyignore.yaml | section 5.9 when added |

## 5. Procedures

### 5.1 Harness tools

For trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind, kubectl:

```bash
scripts/update-tool-checksums.sh trivy 0.76.0   # download exact upstream release checksums
make tools && HARNESS_STRICT=1 make verify build
git diff tools/                                  # versions.env + checksums.txt
```

The script reads exact-release checksums. Shellcheck publishes none: it downloads three artifacts
and computes SHA256. Read release notes first; a new Trivy version may reveal new findings.

### 5.2 npm dependencies

Review Dependabot CI/release notes. For manual updates, use exact versions and update the lock:

```bash
npm install --save-exact --workspace api express@5.3.1   # or web, or root without workspace
HARNESS_STRICT=1 make verify build && make e2e
```

Keep TypeScript within typescript-eslint's range, @types/node matching .nvmrc major, and
@vitejs/plugin-react compatible with Vite major. Close an incompatible Dependabot PR with a reason;
never force npm ERESOLVE with --legacy-peer-deps. Port bumps to the other apps (section 5.10).

### 5.3 Node.js major, for example 24 → 26

1. .nvmrc and engines.node in all three package.json files (`>=26 <27`); @types/node 26.
2. Both Dockerfiles use the same digest-pinned `node:26-alpine<version>` builder;
   API runtime `gcr.io/distroless/nodejs26-debian13:nonroot`.
3. Digest-pinned `javascript-node:26-*` devcontainer.
4. `HARNESS_STRICT=1 make verify build && make e2e`; version-consistency finds omissions.

### 5.4 Image digests

```bash
docker buildx imagetools inspect node:24-alpine3.24   # also nginxinc/nginx-unprivileged:1.30-alpine-slim
docker buildx imagetools inspect gcr.io/distroless/nodejs24-debian13:nonroot
docker buildx imagetools inspect postgres:17-alpine
docker buildx imagetools inspect mcr.microsoft.com/devcontainers/javascript-node:24-trixie
```

Use the multi-platform index digest; update tag/date comments. PostgreSQL's digest appears in
Compose, ci.yml, local/postgres.yaml and harness; version-consistency requires all four to agree.
Check the actual in-image version: tags may stop rebuilding. App base-image digests remain
coordinated with dx02v2/dx03v2.

### 5.5 Kubernetes, kind and EKS

1. `scripts/update-tool-checksums.sh kind <version>`; node image in kind/kind-config.yaml comes
   from release notes with @sha256.
2. kubectl matches node minor: `scripts/update-tool-checksums.sh kubectl <version>`.
3. K8S_SCHEMA_KUBERNETES_VERSION in harness and a K8S_SCHEMA_REF containing it;
   version-consistency requires matching node/kubectl/schema minors.
4. EKS minor belongs to tx01v2's contract; coordinate both repositories.

### 5.6 Red Trivy image gate

1. Read trivy-image:* package, installed version and fixed version.
2. Alpine/Debian: refresh base digest (5.4); if unavailable, wait for rebuild or choose another tag.
3. npm: update dependency (5.2); if transitive, use an exact root package.json overrides entry
   explained in the PR.
4. No applicable fix and accepted risk: temporary exception (5.9/GUARDRAILS.md).
   Never reduce severity or disable the gate.

### 5.7 kubeconform schemas

K8S_SCHEMA_REF (yannh/kubernetes-json-schema) and CRD_SCHEMA_REF
(datreeio/CRDs-catalog) in scripts/harness.sh pin commits. Find the ExternalSecret schema:
`gh api 'repos/datreeio/CRDs-catalog/commits?path=external-secrets.io/externalsecret_v1.json&per_page=1'`.
Full/waypoint experimental Gateway API schemas are separately pinned in source.env.

### 5.8 Actions

Outside Dependabot, resolve `gh api repos/<o>/<r>/git/ref/tags/<tag>`. If object.type is tag,
follow `gh api repos/<o>/<r>/git/tags/<sha>`. Pin commit SHA with # vX.Y.Z and verify existence
with `gh api repos/<o>/<r>/commits/<sha>`. Verify actions against official repositories.

### 5.8.1 R7 scanners

Review CodeQL Action, SonarQube Community Build, SonarScanner and ZAP pins through Dependabot
and quarterly maintenance. Read release notes, verify SHA/digest and scanner SHA256, run complete
CI and inspect SARIF/ZAP. Do not lower SARIF thresholds, Quality Gate or failure severity to accept
a finding without documented remediation.

### 5.9 Trivy exception review

For entries near expired_at, reassess the reason. Renew at most approximately seven months with
updated justification if still valid; otherwise fix/remove.

### 5.10 App parity, quarterly and after every app change

api/, web/, e2e/, base manifests and local overlay must match dx02v2/dx03v2 except repository names
and explicit documented cloud adaptations. Compare main below, then repeat with dx03v2:

```bash
ref="$(mktemp -d)"
git clone --quiet https://github.com/maringelix/dx02v2.git "$ref/dx02v2"
for d in api web e2e deploy/k8s/base deploy/k8s/overlays/local; do
  mkdir -p "$ref/norm/$d" && cp -R "$ref/dx02v2/$d/." "$ref/norm/$d/"
done
grep -rlI dx02v2 "$ref/norm" | xargs -r sed -i 's/dx02v2/dx01v2/g'
for d in api web e2e deploy/k8s/base deploy/k8s/overlays/local; do
  diff -ru -x node_modules -x dist -x coverage "$ref/norm/$d" "$d"
done
rm -rf "$ref"
```

Historical expected differences: e2e/smoke.mjs and lib.mjs (SMOKE_EDGE instead of
SMOKE_BEHIND_WAF, exact /api CSP); rate-limit.test.ts comments (AGC/Google LB cases exist in all
three apps); config.test.ts CA example; comments in app.ts/server.ts, web/src/api.ts,
web/vite.config.ts, web/nginx/default.conf and base/local manifests.
All additional differences require investigation: port the lagging fix with one PR per repository,
or record why it is AWS-only. Current family parity checks provide additional evidence.

## 6. Incident response

| Situation | First steps |
|---|---|
| Red CI | read first FAIL and underlying log; fix code without weakening check; reproduce verify/build/e2e |
| Vulnerability | image gate: 5.6; Dependabot/advisory updates through coordinated app PRs; private report: SECURITY.md |
| Exposed credential | local dev-env.sh --force and docker compose -p dx01v2-dev down -v; AWS rotate in Secrets Manager (tx01v2), wait ESO (up to 1h), kubectl -n dx01v2 rollout restart deployment/api; revoke exposed GitHub tokens; history rewrite is maintainer decision |
| Cost alert | tx01v2 destroy/leftovers; app Ingress creates an ALB that bills while provisioned |
| Post-destroy leftovers | tx01v2 runbook; record cloud_run_report |
| Rejected CA/schema download | inspect primary sources and network; do not bypass TLS or digest checks |

## 7. Cloud run records

Every run creates cloud_run_report with date, region, commits, steps, duration,
observed cost, smoke output, issues and leftovers. README status changes only with this evidence.

## 8. Owners

Maintainer: @maringelix (decisions, merges, cloud runs). AI agents follow AGENTS.md.
