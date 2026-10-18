# dx01v2 runbook

Develop and check the app locally (npm, Compose, kind), then publish to tx01v2
EKS. Local development is free and `verified locally`; AWS deployment remains
`not run in the cloud (v2)`. Your run supplies real-account evidence. Start with
the [central guide](https://github.com/maringelix/tx00v2/blob/main/docs/GETTING_STARTED.md).

## 1. Local prerequisites

- Docker and the Docker-in-Docker devcontainer, or Linux/WSL2 with Docker,
  Bash >=4.4, Node.js24 (.nvmrc), curl, unzip, xz, Git and Make.
- make tools installs pinned Trivy, hadolint, actionlint, shellcheck,
  kubeconform, Gitleaks, kind, kubectl and other harness tools into .tools/.
- Ports:8080 (Compose WEB_PORT, loopback only),15432 (development PostgreSQL,
  loopback only),5173 (Vite, loopback only),3000/9464 (development API, all interfaces).

## 2. npm workspaces development

One root package-lock.json; workspaces api and web.

```bash
npm ci
# Disposable PostgreSQL17 on loopback; random password/token in this shell only.
export DB_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export ADMIN_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --rm --name dx01v2-dev-pg -p 127.0.0.1:15432:5432 \
  -e POSTGRES_DB=dx01v2 -e POSTGRES_USER=dx01v2 -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24
export DB_HOST=127.0.0.1 DB_PORT=15432 DB_NAME=dx01v2 DB_USER=dx01v2
node api/src/migrate.ts            # Node.js24 executes TypeScript directly
npm run dev --workspace api        # API3000, metrics9464, reload on save
npm run dev --workspace web        # another terminal: http://127.0.0.1:5173, /api→:3000
docker rm -f dx01v2-dev-pg          # when finished
```

Useful commands: npm run lint, typecheck, format, build.
Web tests: `npm run test:coverage --workspace web`.
API tests use DB_* and **drop/recreate tables**; DB_NAME must end in _test:

```bash
docker exec dx01v2-dev-pg createdb -U dx01v2 dx01v2_test
DB_NAME=dx01v2_test npm run test:coverage --workspace api
```

`HARNESS_STRICT=1 make verify` is the complete gate. Without DB_HOST it creates a
disposable PostgreSQL instance; with DB_* it requires the _test suffix. In this
development shell use `env -u DB_HOST HARNESS_STRICT=1 make verify` for isolation.

## 3. Compose stack (project dx01v2-dev)

```bash
scripts/dev-env.sh                                # random DB_PASSWORD/ADMIN_TOKEN, mode600 .env
docker compose -p dx01v2-dev up -d --build --wait   # db→migrate→api→web
scripts/compose-smoke.sh                          # http://127.0.0.1:8080
docker compose -p dx01v2-dev down -v               # remove containers/network/DB volume
```

- Only web is published on 127.0.0.1, WEB_PORT default8080; API/DB use internal networks.
- Containers: read-only root filesystems, cap_drop ALL, no-new-privileges.
- Page admin accepts .env ADMIN_TOKEN, retained only in tab memory.
- Rotate: scripts/dev-env.sh --force, then down -v (existing DB volume keeps old password).
- Different port: `WEB_PORT=18080 scripts/dev-env.sh --force`.

## 4. kind end to end (make e2e)

```bash
make tools
make e2e                         # create/test/delete dx01v2-e2e
KEEP_CLUSTER=1 make e2e           # retain for investigation
kind get kubeconfig --name dx01v2-e2e > /tmp/dx01v2-e2e.kubeconfig
KUBECONFIG=/tmp/dx01v2-e2e.kubeconfig kubectl -n dx01v2 get pods,svc,networkpolicy
kind delete cluster --name dx01v2-e2e
```

scripts/e2e-kind.sh builds dx01v2-api:e2e and dx01v2-web:e2e, creates the
digest-pinned v1.36.4 kind node, loads images, creates random Secrets, applies
deploy/k8s/overlays/local, waits for rollouts, requires rejection of a privileged
Pod, runs smoke through svc/web port-forward and exercises permitted/blocked
NetworkPolicy paths with disposable Pods. Failure diagnostics:
$TMPDIR/dx01v2-harness/e2e-diagnostics. Complete platform/HA exercises are separate
(LOCAL_LAB/FINOPS). Heavy checks run in Actions.

## 5. AWS prerequisites

> Historical default: US$0.26–0.32/hour in us-east-1 including app Ingress ALB
> (TX COSTS). Use current reviewed FINOPS prices including full/HA/DR. Destroy
> on the same day.

1. Finish TX bootstrap, apply and platform. Bootstrap deploy_role_arn
   (dx01v2-gha-deploy) must be in TX LAB_APP_DEPLOYER_PRINCIPAL_ARNS before apply,
   creating the dx01v2-deployers access entry. A laptop identity needs its own
   explicit ARN, but is not a substitute for workflow-signed full deployment.
2. Apply scripts/repo-guardrails.sh: protected lab with reviewer, main-only.
   Immutable OIDC subject:
   `repo:<owner>@<owner id>/dx01v2@<repository id>:environment:lab`.
3. Configure variables below; private GitOps repos need Argo CD credentials.
4. TX requires pricing/budget/duration/expiry and endpoint Secrets; first full
   install needs escrowed LAB_VELERO_REPOSITORY_PASSWORD (64 random hex characters,
   same key both regions). These remain TX settings.

## 6. GitHub variables

Settings → Secrets and variables → Actions → **Variables**. Public logs can
include these; never store credentials here. Import TX bootstrap
github_variables_dx01v2 from the TX clone as shown in the central guide.

| Variable/configuration | Example | Use |
|---|---|---|
| AWS_REGION | us-east-1 | Matches /tx01v2/lab/region |
| AWS_DEPLOY_ROLE_ARN | arn:aws:iam::<ACCOUNT_ID>:role/dx01v2-gha-deploy | OIDC role |
| LAB_DR_REGION | us-west-2 | Secondary target, matching TX |
| HTTPS/DNS in TX | Paired Secrets LAB_APP_DOMAIN_NAME + LAB_ROUTE53_PUBLIC_ZONE_ID | Contract chooses HTTPS overlay, ExternalDNS host and HTTPS smoke |

## 7. Deploy

Supported chain: **successful current-main push CI → publish-images → deploy-aws**.

1. Dispatch publish-images.yml on main with ci_run_id of successful push CI for
   that same current commit. Publisher checks six source jobs: static, test,
   images, e2e, e2e-platform, continuity. Full CI also runs e2e-platform-small.
   It verifies image IDs/archive checksum, publishes tested GHCR images without
   rebuild and attaches keyless Sigstore SLSA provenance/SPDX SBOM.
2. Dispatch deploy-aws.yml with the successful **publication** release_run_id.
   Choose platform_profile=core|full matching TX, deploy_mode=auto|gitops|push,
   target=primary|secondary. Before lab approval it verifies CI/SBOM/digests/
   exact signer/issuer; after approval it assumes the AWS role through OIDC.
3. It promotes approved GHCR images to ECR without rebuild, compares image
   configuration IDs, resolves final ECR digests and signs promotion under this
   workflow's main identity. Cross-registry manifest digest equality is not
   required. Full requires the programmed waypoint; Kyverno requires promotion
   attestations. Auto selects GitOps if Application dx01v2 exists, direct push
   otherwise; explicit gitops/push is available. It then waits for ExternalSecrets,
   rollouts and smoke.

Deployment does not run Terraform or delete resources. EKS/ALB/RDS continue
billing until TX teardown.

Operator scripts require the downloaded publication bundle, gh/docker and
AWS/GHCR/GitHub authentication. Set RELEASE_DIR/RELEASE_RUN_ID for the selected
bundle/run, GH_TOKEN with actions:read/attestations:read/packages:read and
GITHUB_REPOSITORY/GITHUB_TOKEN with contents:write for GitOps. Run
scripts/verify-release-bundle.sh before scripts/deploy-aws.sh; deployment repeats
verification before AWS access. This laptop path does **not** generate workflow
promotion attestations; full requires the Actions chain. Never bypass admission.

Rollback redeploys the previous approved GitOps digest and waits for rollout.
It does not undo migrations or recover deleted rows. Use MIGRATIONS/CONTINUITY
backup/PITR for data loss. Never edit an applied migration; add a corrective one.

## 8. Inspect

```bash
aws eks update-kubeconfig --name tx01v2-lab --region us-east-1 --kubeconfig ~/.kube/tx01v2-lab.kubeconfig
export KUBECONFIG=~/.kube/tx01v2-lab.kubeconfig   # this terminal only
kubectl -n dx01v2 get pods,ingress,externalsecrets,hpa
curl -fsS "http://<ALB_HOSTNAME>/api/info"       # use HTTPS contract hostname with DNS
```

Host ~/.kube/config is unchanged. After requests, dx01v2-api appears in
same-region X-Ray (CloudWatch traces): API→observability Collector OTLP/HTTP4318
→X-Ray. TX owns Collector/write permission.

The current one-hop API setting behind ALB→nginx does not establish browser-IP
attribution; see ARCHITECTURE. WAF supplies independent edge per-IP controls.

DR target=secondary selects a contract, not database promotion. Follow both
CONTINUITY runbooks: fence old writers, accept lag, explicitly promote, verify
secondary app/TLS/data, then authorize DNS.

## 9. Shut down

TX terraform-destroy runs platform/uninstall.sh, removing Ingresses/ALB before
Terraform, then scripts/leftovers.sh. On core, deleting Ingress dx01v2 removes
only the app ALB. On full, stop owning GitOps reconciliation through TX teardown
first; self-heal otherwise recreates it.

## 10. Common problems

| Symptom | Likely cause | Action |
|---|---|---|
| SSM parameter missing | TX absent in selected region | Apply TX or correct AWS_REGION/target |
| Principal cannot deploy | Missing access entry/group or platform | Add TX LAB_APP_DEPLOYER_PRINCIPAL_ARNS, apply/install TX |
| ExternalSecret not Ready | Missing store/secret | Describe db-credentials; inspect TX |
| migrate TLS failure | Missing/wrong-region rds-ca | Check DB_SSL_CA_FILE and regional CA bundle; deploy recreates ConfigMap |
| Ingress no address | LBC/subnet tags/provisioning | Describe Ingress events |
| Smoke403 everywhere | WAF reputation/rate rule | Inspect aws-waf-logs-tx01v2-lab |
| Immutable tag differs | SHA exists with other image | Deploy compares ECR image ID with approved source and stops; never overwrite |
| No X-Ray trace | Missing/old Collector or permission | Inspect observability Pods/Collector logs; API continues, spans are lost |
| Full admission refuses | Missing/wrong promotion identity | Use Actions publication/deploy, inspect Kyverno |
| Publication rejects source | Wrong event/SHA/checks/artifact | Use successful current-main push CI |

## 11. Record

Open **Cloud run report**: date, region, DX/TX commits, steps/run IDs, duration,
observed cost, smoke output, failures and sanitized TX leftovers. Keep real
identifiers, endpoints, plans/state, tokens and webhook URLs private.
