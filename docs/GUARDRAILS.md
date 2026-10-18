# dx01v2 guardrails

A guardrail combines a rule with enforcement, automated where possible. This document names rules,
enforcement and limits. Types: blocking (fails harness/CI), alert (notifies), process (human/agent
discipline). IDs remain stable, including historical CUSTO/MUD identifiers.

## Rules

| ID | Rule | Reason | Enforcement | Type |
|---|---|---|---|---|
| SEC-01 | No committed secrets | public repository; history persists | gitleaks, harness/pre-commit | blocking |
| SEC-02 | No real identifiers: only account ID `123456789012`/`<ACCOUNT_ID>`, example.com emails, private/RFC5737 IPs | protect accounts and people | policy-identifiers | blocking |
| SEC-03 | Random runtime local credentials with dev-env.sh/e2e-kind.sh; ignored .env; example placeholders; no Secret objects in app manifests | no copied default passwords | .gitignore, gitleaks, contract-app | blocking |
| SEC-04 | GitHub→AWS uses OIDC role dx01v2-gha-deploy and immutable lab subject with owner/repository IDs; CI cannot authenticate to cloud | no static cloud keys; re-registered names inherit no trust | policy-workflows; repo-guardrails.sh checks sub | blocking |
| SEC-05 | Admin token >=32 characters, constant-time comparison; absent token gives503 admin_disabled | prevent weak tokens/timing disclosure | config.ts; admin-auth/config/messages tests | blocking |
| SEC-06 | Redact Authorization, Cookie, password and token fields | no secrets in log aggregators | logger.ts and logger test | blocking |
| SEC-07 | Integration tests recreate tables only with DB_NAME ending _test; deploy-local only targets kind-tx01v2-local | operator DB_* or context may target other work | requireTestDatabase, integration/helpers.ts, test-database/test:api, require_lab_context | blocking |
| SEC-08 | Smoke sends tokens only through HTTPS or loopback; otherwise omits only the credentialed call. AWS deploy reads the app Secret token only when permitted by its smoke path and masks it | unencrypted public ingress must not leak credentials | smoke.mjs, deploy-aws.sh | blocking |
| SUP-01 | Tool versions/SHA256 pinned; mismatch fatal | supply chain | install-tools.sh, checksums.txt | blocking |
| SUP-02 | Every action uses a full 40-character commit SHA with # vX.Y.Z | tags can move | policy-workflows | blocking |
| SUP-03 | Digest-pin Dockerfile/Compose/manifest/CI/kind/devcontainer images/features; no latest | March2026 malicious Trivy latest incident | policy-images | blocking |
| SUP-04 | Exact npm versions, synchronized lock | reproducible builds | version-consistency/npm-ci; strict mode always npm ci | blocking |
| SUP-05 | Install Trivy through install-tools.sh only, never trivy-action/setup-trivy | March2026 incident GHSA-69fq-xp46-6x23 | policy-workflows | blocking |
| SUP-06 | No fixable HIGH/CRITICAL image CVEs | do not publish known fixable vulnerabilities | trivy-image:api/web | blocking |
| SUP-07 | Match Node major across .nvmrc/engines/builder, PostgreSQL digest across Compose/CI/kind/harness, Kubernetes minor across kind/kubectl/schemas | reject partial upgrades | version-consistency | blocking |
| SUP-08 | Monthly npm/docker/actions/pre-commit Dependabot; grouped minor/patch, separate major | detect drift | dependabot.yml | alert |
| K8S-01 | Strict kubeconform with pinned Kubernetes 1.36 and ExternalSecret schemas; full waypoint experimental schemas | invalid manifests cannot reach the cluster | kubeconform | blocking |
| K8S-02 | Restricted Pods: numeric non-root UID, RuntimeDefault, no escalation, drop ALL, read-only root, no SA token/hostPath/host namespaces, requests/memory limits | least privilege, enforced app namespace | contract-app; kind rejects privileged Pod | blocking |
| K8S-03 | Default-deny ingress/egress; allow DNS, web→api:3000, API→PostgreSQL/RDS:5432, ALB public-subnet CIDR→web, approved monitoring and full mesh/Collector paths | prevent lateral access; VPC CIDR is only DB egress | contract-app, kind probes | blocking |
| K8S-04 | aws* overlays contain only kinds the dx01v2-deployer roles can write; TX owns namespace/RBAC | least-privilege deployment | contract-app | blocking |
| K8S-05 | No HIGH/CRITICAL rendered-manifest/Dockerfile findings | secure configuration | trivy-config | blocking |
| K8S-06 | Entry through dx01v2 Gateway/HTTPRoute (/api→api3000, /→web8080), /healthz and /readyz policies, optional whole-Gateway WAF; full adds HTTPS/HTTP redirect | no uncontracted exposure | contract-app | blocking |
| APP-01 | trust proxy is TRUST_PROXY_HOPS count, never true; limiter uses req.ip | forged XFF cannot bypass | policy-app, rate-limit tests, forged-XFF429 smoke | blocking |
| APP-02 | Same-origin without CORS middleware/pre-storage HTML escaping; UI renders text | avoid v1 localhost-only CORS | policy-app; tests/smoke preserve literal <b> | blocking |
| APP-03 | No inline UI style/scripts; CSP script-src self/style-src self; no sourcemaps | prevent v1 unsafe-inline/public maps | policy-app, smoke, image-policy:web | blocking |
| APP-04 | nginx security headers on responses/assets/errors; HSTS only HTTPS; server_tokens off | v1 preload-HSTS over HTTP | policy-app, smoke | blocking |
| APP-05 | JSON error.code/message/requestId, no internals, for400/413/404/415/429/500/503 | v1 returned500 for everything | integration/smoke | blocking |
| APP-06 | pino-only JSON logs with request ID per line | structured/redacted logs | policy-app forbids console.*, eslint no-console | blocking |
| APP-07 | Browser admin token only in memory | no localStorage/cookie credentials | policy-app | blocking |
| APP-08 | Distroless API without shell/npm/npx/corepack; both images numeric non-root uid:gid and OCI source/revision | reduce attack surface | policy-images, image-policy:api/web, hadolint | blocking |
| APP-09 | API >=80% lines/>=70% branches, web >=70% lines on real code | no expect(true).toBe(true) substitutes | Vitest thresholds | blocking |
| APP-10 | Never edit applied migration; schema_migrations checksum; transaction per migration, advisory lock | concurrent replicas/initContainers cannot corrupt schema | migrate.ts, migrations tests | blocking |
| APP-11 | Versioned TX contract; coordinated interface PRs | both sides evolve together | CONTRACT.md, contract-app | process |
| APP-12 | api/web/e2e parity across all three apps or explicit cloud-specific justification | fair comparison | PR template, MAINTENANCE routine | process |
| CUSTO-01 | Explicit workflow_dispatch release/deploy; validated ci_run_id/release_run_id, protected lab; GitOps contents:write only deploy | deliberate intent/bounded push rights | policy-workflows, publish-gitops.sh | blocking |
| CUSTO-02 | Same-day TX destroy, leftovers and cloud_run_report | ALB, EKS, RDS and other provisioned services incur costs | RUNBOOK.md | process |
| CUSTO-03 | Never replace immutable ECR tags; verify promoted image configuration IDs and final digests | avoid substitution and wasted deployment | deploy-aws.sh | blocking during deploy |
| CI-01 | Harness is CI; checks in harness.sh, jobs call make targets | local reproducibility | PR review, ci.yml | process |
| CI-02 | No continue-on-error:true, `\|\| true`, `\|\| echo` workflows | meaningful gates; v1 lint only ran npm install | policy-workflows | blocking |
| CI-03 | Top-level contents:read, timeout/concurrency, ubuntu-24.04, persist-credentials:false | least privilege/predictability | policy-workflows | blocking |
| CI-04 | Strict CI makes SKIP fail, requires pinned versions, no cloud secrets | no silent skips/missing-secret failures | ci.yml, harness | blocking |
| CI-05 | e2e loads images job's exact built/scanned artifact | cluster bytes match scanned bytes | ci.yml | process |
| CI-06 | Weekly Monday06:00UTC CI | detect new CVEs, expiry, broken URLs | ci.yml | alert |
| MUD-01 | Main ruleset requires PR, strict static/test/images/e2e/e2e-platform, no force push | harness every change | ruleset/main.json, repo-guardrails.sh | blocking after publication |
| MUD-02 | Scanner exceptions require statement/expired_at within approximately7months | bounded review | trivyignore-policy | blocking |
| MUD-03 | Conventional Commits, one topic/PR, Unreleased CHANGELOG | readable history | PR template | process |
| DOC-01 | English-only docs/README, exact evidence labels, no self-ratings, UTF-8/LF | prevent v1 false claims/UTF-16 | repo-structure, review | blocking |
| DOC-02 | Docs updated with code | prevent stale instructions | PR template | process |
| AGT-01 | Never mutate cloud without explicit human request for task | cost/security | AGENTS.md | process |
| AGT-02 | Never weaken gates/coverage or add unjustified/unbounded ignores | meaningful harness | AGENTS/checks above | process |
| LOC-01 | Local app through GitOps/ArgoCD/AppProject dx01v2 only, no direct apply | one owner; v1 had two | deploy-local.sh, gitops probe | blocking in e2e-platform |
| LOC-02 | Local STRICT mTLS, identity AuthorizationPolicy, NetworkPolicy with HBONE/ambient kubelet probes | identity, not IP alone | local-platform contract-app, mesh probe | blocking |
| LOC-03 | Alerts use exported app/KSM series with promtool tests | v1 used nonexistent series | promtool-rules, observability | blocking |
| AGT-03 | Stop/ask for AGENTS-listed situations | costly decisions stay human | AGENTS.md | process |

Release workflows request GitHub OIDC for Sigstore signing, separately from cloud credentials.
CI itself receives neither cloud secrets nor cloud authentication.

## Exceptions

A scanner exception must:

1. Represent a deliberate tradeoff or a finding currently impossible to fix, not a hidden defect.
2. Add .trivyignore.yaml id, narrowest paths/purls, statement (acceptance and compensating
   controls), and expired_at within approximately seven months.
3. Be explained in the PR. trivyignore-policy rejects missing reasons/dates, expired entries
   and excessive durations; Trivy no longer applies an expired entry.

Other exclusions are fixed and explained by the checks. policy-identifiers omits generated
lockfiles/checksums where appropriate; Family comparisons are documented in README, ARCHITECTURE and CHANGELOG.

Trivy exception baseline checked 2026-10-10: none. Image scans use --ignore-unfixed:
unfixed and LOW/MEDIUM findings do not fail builds; full counts remain in summaries.

## Limits

- Nothing in v2 ran in AWS: deploy, ESO, ALB, WAF and RDS verify-full are rendered/
  validated offline, not exercised in an AWS account.
- kind checks kindnet/kube-network-policies, not EKS VPC CNI; actual ALB/RDS CIDRs
  exist only in aws* overlays.
- Write rate limits are in memory per API replica: N replicas can allow N times
  the configured limit. TX WAF adds an edge per-IP limit.
- The shared admin token has no users or automatic rotation. Rotate in Secrets
  Manager, wait for ESO and restart API Pods.
- AWS smoke reads app-secrets through deployer Secret-read permission and masks
  the token in Actions logs; control of that deploy identity remains sensitive.
  Smoke never sends credentials over a non-loopback HTTP connection.
- ECR promotion/admission behavior remains an AWS acceptance test. CI checks
  signed predicates, policy structure and negative fixtures, not a live AWS webhook.
- Trivy --ignore-unfixed does not block unfixed CVEs; weekly CI reevaluates them.
- HSTS depends on trusted HTTPS proxy information. Basic Compose/kind is HTTP;
  complete local-platform uses lab-CA TLS, without proving public certificate issuance.
- Before the first commit, Gitleaks scans Git-visible tracked/unignored files;
  afterwards it also scans full history.
- Executable-bit checks cover files already in the Git index.

## Verification

```bash
make tools                       # pinned .tools binaries
HARNESS_STRICT=1 make verify
HARNESS_STRICT=1 make build
make e2e
scripts/harness.sh list           # every check and stage
```
