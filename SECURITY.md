# Security policy

## Reporting a vulnerability

Report privately through GitHub: **Security > Report a vulnerability** on this repository (private
vulnerability reporting is enabled when the repository is public, see `docs/PUBLICACAO.md`). Do not
open a public issue. Never include credentials, admin tokens, AWS account IDs or IP addresses; use
placeholders.

This is a personal educational project: reports are handled on a best-effort basis, with no response
time guarantee and no bug bounty.

## Supported versions

Only the latest commit on `main`. There are no releases yet.

## What this repository does to stay safe

The rules, where each one is enforced and the known limits are in
[docs/GUARDRAILS.md](docs/GUARDRAILS.md). In short:

- The harness (`make verify`, `make build`, `make e2e`, also the CI) runs gitleaks, eslint with
  type-aware rules, hadolint, actionlint, shellcheck, kubeconform, trivy (config and images,
  HIGH/CRITICAL with a fix available) and policy checks that block real identifiers, unpinned
  actions and images, and the regressions found in v1.
- API: input validated with zod (control characters rejected, text stored as received and rendered
  as text by the UI), JSON errors without internals, `trust proxy` as a hop count so spoofed
  `X-Forwarded-For` entries cannot bypass the per-client write rate limit (tested), admin token
  compared in constant time and never logged, credentials redacted from logs.
- Web: strict Content-Security-Policy without inline scripts or styles, security headers on every
  response including static assets, HSTS only for requests that arrived over HTTPS.
- Containers run as numeric non-root users with a read-only root filesystem; the API runtime image
  is distroless (no shell, no npm). Kubernetes: Pod Security `restricted`, default-deny
  NetworkPolicies (enforcement proven on kind), no service account tokens.
- GitHub Actions reach AWS only through the OIDC role `dx01v2-gha-deploy` (environment `lab`); there
  are no static keys. Runtime secrets on AWS come from Secrets Manager through External Secrets.
- Every harness tool is pinned by version and SHA256; actions by commit SHA; images by digest; npm
  dependencies by exact version and a committed lockfile.

## Known limits

The AWS deploy has never run (`not run in the cloud (v2)`). The admin token is a single shared bearer
token (no users, no rotation automation). The write rate limit is kept in memory per API replica, so
the effective limit grows with the number of replicas; the WAF of tx01v2 adds a per-IP limit at the
edge. The kind e2e proves NetworkPolicy enforcement with kindnet, not with the VPC CNI of EKS. See
the "Limites" section of docs/GUARDRAILS.md.
